using System.Text.Json;
using Npgsql;
using static Nephos.Library.Api.Assets.PostgresGalleryJournal;

namespace Nephos.Library.Api.Assets;

public sealed record MediaResource(Guid AssetId, string Role, string Sha256, long Size, string FileName, string UniformTypeIdentifier);
public sealed record ResourceSetInput(string Kind, string SourceRevision, Guid PrimaryAssetId, MediaResource[] Resources)
{
    private static readonly HashSet<string> Roles =
        ["photo", "video", "pairedVideo", "alternatePhoto", "fullSizePhoto", "fullSizeVideo", "adjustmentData",
         "adjustmentBasePhoto", "fullSizePairedVideo", "adjustmentBasePairedVideo", "adjustmentBaseVideo", "audio"];

    public bool IsValid()
    {
        if (Kind is not ("single" or "live-photo" or "raw-jpeg" or "edited" or "archive") ||
            string.IsNullOrWhiteSpace(SourceRevision) || SourceRevision.Length > 1024 ||
            PrimaryAssetId == Guid.Empty || Resources is not { Length: >= 1 and <= 16 } ||
            Resources.Any(r => r is null) || Resources.Select(r => r.AssetId).Distinct().Count() != Resources.Length ||
            !Resources.Any(r => r.AssetId == PrimaryAssetId))
            return false;
        if (Resources.Any(r => r.AssetId == Guid.Empty || !Roles.Contains(r.Role ?? "") || r.Size is <= 0 or > Nephos.ServiceDefaults.MediaProtocol.MaxUploadBytes ||
            r.Sha256 is not { Length: 64 } || !r.Sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') ||
            string.IsNullOrWhiteSpace(r.FileName) || r.FileName.Length > 200 || r.FileName.Any(c => char.IsControl(c) || c is '/' or '\\') ||
            string.IsNullOrWhiteSpace(r.UniformTypeIdentifier) || r.UniformTypeIdentifier.Length > 200 ||
            r.UniformTypeIdentifier.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-'))))
            return false;
        return Kind switch
        {
            "single" => Resources.Length == 1,
            "live-photo" => Resources.Length == 2 && Resources.Any(r => r.Role == "photo") && Resources.Any(r => r.Role == "pairedVideo"),
            "raw-jpeg" => Resources.Length == 2 && Resources.Any(r => r.Role == "photo") && Resources.Any(r => r.Role == "alternatePhoto"),
            _ => true
        };
    }
}

public sealed record ResourceSetManifest(Guid Id, Guid LibraryId, string Kind, string SourceRevision,
    Guid PrimaryAssetId, MediaResource[] Resources, DateTimeOffset CreatedAt);

public interface IResourceSetRepository
{
    Task<ResourceSetManifest> CommitAsync(string subject, Guid library, Guid id, ResourceSetInput input, CancellationToken token);
    Task<ResourceSetManifest?> FindAsync(string subject, Guid id, bool owned, CancellationToken token);
    Task<ResourceSetManifest?> ForAssetAsync(string subject, Guid asset, CancellationToken token);
}

public sealed class PostgresResourceSetRepository(NpgsqlDataSource source) : IResourceSetRepository
{
    private static ResourceSetManifest Read(NpgsqlDataReader reader)
    {
        var input = JsonSerializer.Deserialize<ResourceSetInput>(reader.GetString(2), Json)!;
        return new(reader.GetGuid(0), reader.GetGuid(1), input.Kind, input.SourceRevision,
            input.PrimaryAssetId, input.Resources, reader.GetFieldValue<DateTimeOffset>(3));
    }

    public async Task<ResourceSetManifest?> FindAsync(string subject, Guid id, bool owned, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var query = Command(connection, null, """
            SELECT s.id,s.library_id,s.manifest::text,s.created_at
            FROM resource_sets s
            WHERE s.id=$1 AND can_read_asset($2,s.primary_asset_id) AND (NOT $3 OR s.subject=$2)
            """, id, subject, owned);
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? Read(reader) : null;
    }

    public async Task<ResourceSetManifest?> ForAssetAsync(string subject, Guid asset, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var query = Command(connection, null, """
            SELECT s.id,s.library_id,s.manifest::text,s.created_at
            FROM assets a JOIN resource_sets s ON s.id=a.resource_set_id
            WHERE a.id=$1 AND can_read_asset($2,a.id) AND can_read_asset($2,s.primary_asset_id)
            """, asset, subject);
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? Read(reader) : null;
    }

    public async Task<ResourceSetManifest> CommitAsync(string subject, Guid library, Guid id, ResourceSetInput input, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var access = Command(connection, transaction, """
            SELECT EXISTS(SELECT 1 FROM library_members m JOIN principals p ON p.subject=m.subject
                WHERE m.library_id=$1 AND m.subject=$2 AND p.enabled)
            """, library, subject))
            if (!(bool)(await access.ExecuteScalarAsync(token))!) throw new GalleryAccessException();
        var frontier = await LockAsync(connection, transaction, library, token);
        var serialized = JsonSerializer.Serialize(input, Json);
        await using (var existing = Command(connection, transaction,
            "SELECT library_id,subject,manifest::text,created_at FROM resource_sets WHERE id=$1", id))
        await using (var reader = await existing.ExecuteReaderAsync(token))
        {
            if (await reader.ReadAsync(token))
            {
                var previous = JsonSerializer.Deserialize<ResourceSetInput>(reader.GetString(2), Json)!;
                if (reader.GetGuid(0) != library || reader.GetString(1) != subject ||
                    JsonSerializer.Serialize(previous, Json) != serialized)
                    throw new ResourceConflictException("Resource-set ID is already bound to another immutable manifest.");
                return new(id, library, input.Kind, input.SourceRevision, input.PrimaryAssetId, input.Resources, reader.GetFieldValue<DateTimeOffset>(3));
            }
        }
        var changes = new List<(Asset Asset, bool Visible)>();
        foreach (var resource in input.Resources)
        {
            await using var query = Command(connection, transaction, """
                SELECT id,file_name,media_type,size,sha256,has_preview,created_at FROM assets
                WHERE id=$1 AND library_id=$2 AND uploaded_by=$3 AND resource_set_id IS NULL
                    AND (pending_resource_set_id IS NULL OR pending_resource_set_id=$4)
                """, resource.AssetId, library, subject, id);
            await using var reader = await query.ExecuteReaderAsync(token);
            if (!await reader.ReadAsync(token) || reader.GetInt64(3) != resource.Size ||
                reader.GetString(4) != resource.Sha256 || reader.GetString(1) != resource.FileName)
                throw new ResourceConflictException("A resource is missing, unowned, already grouped, or does not match the manifest.");
            changes.Add((new(reader.GetGuid(0), library, reader.GetString(1), reader.GetString(2), reader.GetInt64(3),
                reader.GetString(4), reader.GetBoolean(5), reader.GetFieldValue<DateTimeOffset>(6), id),
                resource.AssetId == input.PrimaryAssetId));
        }
        DateTimeOffset created;
        await using (var insert = Command(connection, transaction, """
            INSERT INTO resource_sets(id,library_id,subject,primary_asset_id,manifest) VALUES($1,$2,$3,$4,$5::jsonb) RETURNING created_at
            """, id, library, subject, input.PrimaryAssetId, serialized))
        await using (var reader = await insert.ExecuteReaderAsync(token))
        {
            await reader.ReadAsync(token);
            created = reader.GetFieldValue<DateTimeOffset>(0);
        }
        foreach (var (asset, visible) in changes)
        {
            await using var update = Command(connection, transaction,
                "UPDATE assets SET resource_set_id=$2,hidden=$3 WHERE id=$1", asset.Id, id, !visible);
            await update.ExecuteNonQueryAsync(token);
        }
        await AppendAsync(connection, transaction, library, frontier + 1, changes, token);
        await transaction.CommitAsync(token);
        return new(id, library, input.Kind, input.SourceRevision, input.PrimaryAssetId, input.Resources, created);
    }
}
