using System.Text.Json;
using Npgsql;

namespace Nephos.Library.Api.Assets;

public sealed record AssetChange(string Operation, Guid AssetId, Asset? Asset);
public sealed record GalleryChange(long Revision, IReadOnlyList<AssetChange> Items);

internal static class PostgresGalleryJournal
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    internal static NpgsqlCommand Command(NpgsqlConnection connection, NpgsqlTransaction? transaction, string sql, params object[] values)
    {
        var command = new NpgsqlCommand(sql, connection, transaction);
        foreach (var value in values) command.Parameters.AddWithValue(value);
        return command;
    }

    internal static async Task<long> LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid library, CancellationToken token)
    {
        await using (var ensure = Command(connection, transaction,
            "INSERT INTO gallery_frontiers(library_id) VALUES($1) ON CONFLICT DO NOTHING", library))
            await ensure.ExecuteNonQueryAsync(token);
        await using var read = Command(connection, transaction,
            "SELECT revision FROM gallery_frontiers WHERE library_id=$1 FOR UPDATE", library);
        return (long)(await read.ExecuteScalarAsync(token))!;
    }

    internal static async Task AppendAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid library,
        long revision, IReadOnlyList<(Asset Asset, bool Visible)> changes, CancellationToken token)
    {
        for (var index = 0; index < changes.Count; index++)
        {
            var (asset, visible) = changes[index];
            var body = JsonSerializer.Serialize(asset, Json);
            await using (var close = Command(connection, transaction,
                "UPDATE gallery_versions SET to_revision=$2 WHERE asset_id=$1 AND to_revision IS NULL", asset.Id, revision))
                await close.ExecuteNonQueryAsync(token);
            await using (var version = Command(connection, transaction, """
                INSERT INTO gallery_versions(library_id,asset_id,from_revision,visible,created_at,body)
                VALUES($1,$2,$3,$4,$5,$6::jsonb)
                """, library, asset.Id, revision, visible, asset.CreatedAt, body))
                await version.ExecuteNonQueryAsync(token);
            await using (var change = Command(connection, transaction, """
                INSERT INTO gallery_changes(library_id,revision,ordinal,asset_id,operation,body)
                VALUES($1,$2,$3,$4,$5,CASE WHEN $6 THEN $7::jsonb ELSE NULL END)
                """, library, revision, index, asset.Id, visible ? "upsert" : "remove", visible, body))
                await change.ExecuteNonQueryAsync(token);
            if (visible)
            {
                await using var publication = Command(connection, transaction, """
                    INSERT INTO face_publications(asset_id)
                    SELECT id FROM analysis_sources WHERE id=$1
                    ON CONFLICT(asset_id) DO NOTHING
                    """, asset.Id);
                await publication.ExecuteNonQueryAsync(token);
            }
        }
        await using var frontier = Command(connection, transaction,
            "UPDATE gallery_frontiers SET revision=$2 WHERE library_id=$1", library, revision);
        await frontier.ExecuteNonQueryAsync(token);
    }
}
