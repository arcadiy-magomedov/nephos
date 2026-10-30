using System.Security.Cryptography;
using Npgsql;

if (args.Length != 1 || args[0] is not ("library" or "storage" or "faces"))
{
    Console.Error.WriteLine("Usage: Nephos.Migrations <library|storage|faces>");
    return 2;
}

var connectionString = Environment.GetEnvironmentVariable("MIGRATION_CONNECTION")
    ?? throw new InvalidOperationException("MIGRATION_CONNECTION is required.");
await using var connection = new NpgsqlConnection(connectionString);
await connection.OpenAsync();
await using var transaction = await connection.BeginTransactionAsync();
await using (var setup = new NpgsqlCommand("""
    SELECT pg_advisory_xact_lock(48465001);
    CREATE TABLE IF NOT EXISTS schema_migrations (
        name text PRIMARY KEY,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
    );
    """, connection, transaction))
{
    await setup.ExecuteNonQueryAsync();
}
var assembly = typeof(Program).Assembly;
foreach (var name in assembly.GetManifestResourceNames()
             .Where(n => n.StartsWith($"Nephos.Migrations.Sql.{args[0]}.", StringComparison.Ordinal))
             .Order(StringComparer.Ordinal))
{
    await using var stream = assembly.GetManifestResourceStream(name)
        ?? throw new InvalidOperationException($"Missing migration resource: {name}");
    using var reader = new StreamReader(stream);
    var sql = await reader.ReadToEndAsync();
    var checksum = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(sql)));
    await using var check = new NpgsqlCommand(
        "SELECT checksum FROM schema_migrations WHERE name = $1", connection, transaction);
    check.Parameters.AddWithValue(name);
    var existing = await check.ExecuteScalarAsync();
    if (existing is string stored)
    {
        if (stored != checksum)
        {
            throw new InvalidOperationException($"Applied migration changed: {name}");
        }
        continue;
    }
    await using var apply = new NpgsqlCommand(sql, connection, transaction);
    await apply.ExecuteNonQueryAsync();
    await using var record = new NpgsqlCommand(
        "INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)", connection, transaction);
    record.Parameters.AddWithValue(name);
    record.Parameters.AddWithValue(checksum);
    await record.ExecuteNonQueryAsync();
    Console.WriteLine($"Applied {name}");
}
await transaction.CommitAsync();
Console.WriteLine("Migrations complete.");
return 0;
