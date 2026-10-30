using Nephos.Library.Api.Assets;
using Npgsql;
using static Nephos.Library.Api.Assets.PostgresGalleryJournal;

namespace Nephos.Library.Api.Sharing;

public sealed record DirectoryUser(string Id, string Name);
public sealed record ShareInput(Guid LibraryId, string RecipientId, bool AllAssets, Guid[] AssetIds)
{
    public bool IsValid() => LibraryId != Guid.Empty && Guid.TryParse(RecipientId, out _) &&
        AssetIds is not null && AssetIds.Length <= 500 && AssetIds.All(id => id != Guid.Empty) &&
        AssetIds.Distinct().Count() == AssetIds.Length && (AllAssets ? AssetIds.Length == 0 : AssetIds.Length > 0);
}
public sealed record MediaShare(Guid Id, Guid LibraryId, string LibraryName, string OwnerId, string OwnerName,
    string RecipientId, string RecipientName, bool AllAssets, Guid[] AssetIds, DateTimeOffset CreatedAt);
public interface ISharingRepository
{
    Task<IReadOnlyList<DirectoryUser>> DirectoryAsync(string subject, string? after, int limit, CancellationToken token);
    Task<IReadOnlyList<MediaShare>> ListAsync(string subject, Guid? after, int limit, CancellationToken token);
    Task<MediaShare> PutAsync(string subject, Guid id, ShareInput input, CancellationToken token);
    Task<bool> DeleteAsync(string subject, Guid id, CancellationToken token);
}

public sealed class PostgresSharingRepository(NpgsqlDataSource source) : ISharingRepository
{
    private const string Select = """
        SELECT s.id,s.library_id,l.name,s.owner_subject,coalesce(o.display_name,'Known user'),
            s.recipient_subject,coalesce(r.display_name,'Known user'),s.all_assets,
            ARRAY(SELECT i.asset_id FROM share_items i JOIN assets a ON a.id=i.asset_id
                WHERE i.share_id=s.id AND NOT a.hidden ORDER BY i.asset_id),s.created_at
        FROM shares s JOIN libraries l ON l.id=s.library_id
        JOIN principals o ON o.subject=s.owner_subject JOIN principals r ON r.subject=s.recipient_subject
        """;
    private static MediaShare Read(NpgsqlDataReader r) => new(r.GetGuid(0), r.GetGuid(1), r.GetString(2),
        r.GetString(3), r.GetString(4), r.GetString(5), r.GetString(6), r.GetBoolean(7),
        r.GetFieldValue<Guid[]>(8), r.GetFieldValue<DateTimeOffset>(9));

    public async Task<IReadOnlyList<DirectoryUser>> DirectoryAsync(string subject, string? after, int limit, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var query = Command(connection, null, """
            SELECT subject,display_name FROM principals WHERE enabled AND discoverable AND display_name IS NOT NULL
            AND subject<>$1 AND subject>$2 AND EXISTS(SELECT 1 FROM principals WHERE subject=$1 AND enabled)
            ORDER BY subject LIMIT $3
            """, subject, after ?? "", limit);
        await using var reader = await query.ExecuteReaderAsync(token);
        var users = new List<DirectoryUser>();
        while (await reader.ReadAsync(token)) users.Add(new(reader.GetString(0), reader.GetString(1)));
        return users;
    }

    public async Task<IReadOnlyList<MediaShare>> ListAsync(string subject, Guid? after, int limit, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var query = Command(connection, null, Select + """
             WHERE (s.owner_subject=$1 OR s.recipient_subject=$1) AND s.id>$2
             AND EXISTS(SELECT 1 FROM principals WHERE subject=$1 AND enabled)
             ORDER BY s.id LIMIT $3
            """, subject, after ?? Guid.Empty, limit);
        await using var reader = await query.ExecuteReaderAsync(token);
        var shares = new List<MediaShare>();
        while (await reader.ReadAsync(token)) shares.Add(Read(reader));
        return shares;
    }

    public async Task<MediaShare> PutAsync(string subject, Guid id, ShareInput input, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var access = Command(connection, transaction, """
            SELECT EXISTS(SELECT 1 FROM library_members m JOIN principals p ON p.subject=m.subject
                WHERE m.library_id=$1 AND m.subject=$2 AND p.enabled)
            AND EXISTS(SELECT 1 FROM principals WHERE subject=$3 AND enabled AND discoverable AND display_name IS NOT NULL)
            """, input.LibraryId, subject, input.RecipientId))
            if (subject == input.RecipientId || !(bool)(await access.ExecuteScalarAsync(token))!) throw new GalleryAccessException();
        await LockAsync(connection, transaction, input.LibraryId, token);
        await using (var existing = Command(connection, transaction,
            "SELECT owner_subject,recipient_subject,library_id FROM shares WHERE id=$1 FOR UPDATE", id))
        await using (var reader = await existing.ExecuteReaderAsync(token))
            if (await reader.ReadAsync(token) && (reader.GetString(0) != subject ||
                reader.GetString(1) != input.RecipientId || reader.GetGuid(2) != input.LibraryId))
                throw new ResourceConflictException("Share identity is bound to another owner, recipient or library.");
        await using (var roots = Command(connection, transaction, """
            SELECT count(*) FROM assets WHERE id=ANY($1) AND library_id=$2 AND uploaded_by=$3 AND NOT hidden
            """, input.AssetIds, input.LibraryId, subject))
            if ((long)(await roots.ExecuteScalarAsync(token))! != input.AssetIds.Length)
                throw new ResourceConflictException("Only your committed gallery items can be shared.");
        try
        {
            await using var write = Command(connection, transaction, """
                INSERT INTO shares(id,library_id,owner_subject,recipient_subject,all_assets) VALUES($1,$2,$3,$4,$5)
                ON CONFLICT(id) DO UPDATE SET all_assets=EXCLUDED.all_assets
                """, id, input.LibraryId, subject, input.RecipientId, input.AllAssets);
            await write.ExecuteNonQueryAsync(token);
        }
        catch (PostgresException exception) when (exception.SqlState == PostgresErrorCodes.UniqueViolation)
        { throw new ResourceConflictException("A share already exists for this recipient and library. Update that share instead."); }
        await using (var clear = Command(connection, transaction, "DELETE FROM share_items WHERE share_id=$1", id))
            await clear.ExecuteNonQueryAsync(token);
        if (!input.AllAssets)
        {
            await using var items = Command(connection, transaction, """
                INSERT INTO share_items(share_id,asset_id)
                SELECT $1,id FROM assets WHERE library_id=$2 AND uploaded_by=$3 AND
                  (id=ANY($4) OR resource_set_id IN (SELECT resource_set_id FROM assets WHERE id=ANY($4)))
                """, id, input.LibraryId, subject, input.AssetIds);
            await items.ExecuteNonQueryAsync(token);
        }
        await BumpAsync(connection, transaction, input.RecipientId, token);
        MediaShare result;
        await using (var query = Command(connection, transaction, Select + " WHERE s.id=$1", id))
        await using (var reader = await query.ExecuteReaderAsync(token))
        {
            await reader.ReadAsync(token);
            result = Read(reader);
        }
        await transaction.CommitAsync(token);
        return result;
    }

    public async Task<bool> DeleteAsync(string subject, Guid id, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        string? recipient;
        await using (var remove = Command(connection, transaction, """
            DELETE FROM shares WHERE id=$1 AND (owner_subject=$2 OR recipient_subject=$2)
            AND EXISTS(SELECT 1 FROM principals WHERE subject=$2 AND enabled) RETURNING recipient_subject
            """, id, subject))
            recipient = await remove.ExecuteScalarAsync(token) as string;
        if (recipient is null) return false;
        await BumpAsync(connection, transaction, recipient, token);
        await transaction.CommitAsync(token);
        return true;
    }

    private static async Task BumpAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string subject, CancellationToken token)
    {
        await using var update = Command(connection, transaction,
            "UPDATE principals SET share_generation=share_generation+1 WHERE subject=$1", subject);
        await update.ExecuteNonQueryAsync(token);
    }
}
