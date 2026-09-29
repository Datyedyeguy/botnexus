using System.Security.Cryptography;
using System.Text.Json;

namespace BotNexus.Cli.Commands;

/// <summary>
/// Synchronizes repository-owned BotNexus workflow skills into a BotNexus home.
/// Repository/package content is authoritative; unrelated user skills are untouched.
/// </summary>
internal static class BundledSkillInstaller
{
    private const string ManagedMarkerFile = ".botnexus-managed.json";

    internal static readonly string[] ManagedSkillNames =
    [
        "botnexus-backlog-grooming",
        "botnexus-pr-execution"
    ];

    internal static string ResolvePackagedSkillsRoot()
        => Path.Combine(AppContext.BaseDirectory, "BundledSkills");

    internal static string ResolveRepositorySkillsRoot(string repositoryRoot)
        => Path.Combine(repositoryRoot, "skills");

    internal static BundledSkillSyncResult Synchronize(string sourceRoot, string homePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(homePath);

        var destinationRoot = Path.Combine(homePath, "skills");
        Directory.CreateDirectory(destinationRoot);
        var backupRoot = Path.Combine(homePath, "skill-backups");
        var synchronized = 0;
        var unchanged = 0;
        var backups = new List<string>();

        foreach (var skillName in ManagedSkillNames)
        {
            var sourceSkill = Path.Combine(sourceRoot, skillName);
            if (!File.Exists(Path.Combine(sourceSkill, "SKILL.md")))
                continue;

            var result = SynchronizeSkill(skillName, sourceSkill, destinationRoot, backupRoot);
            if (result.Changed)
                synchronized++;
            else
                unchanged++;
            if (result.BackupPath is not null)
                backups.Add(result.BackupPath);
        }

        return new BundledSkillSyncResult(synchronized, unchanged, backups);
    }

    private static SkillSyncResult SynchronizeSkill(
        string skillName,
        string sourceSkill,
        string destinationRoot,
        string backupRoot)
    {
        var destinationSkill = Path.Combine(destinationRoot, skillName);
        var sourceDigest = ComputeTreeDigest(sourceSkill);
        var existingMarker = ReadMarker(Path.Combine(destinationSkill, ManagedMarkerFile));
        if (existingMarker?.Digest == sourceDigest)
            return new SkillSyncResult(false, null);

        string? backupPath = null;
        var stagingRoot = Path.Combine(destinationRoot, $".deploy-{skillName}-{Guid.NewGuid():N}");
        var replacedRoot = Path.Combine(destinationRoot, $".replaced-{skillName}-{Guid.NewGuid():N}");
        try
        {
            CopyTree(sourceSkill, stagingRoot);
            WriteMarker(stagingRoot, new ManagedSkillMarker(skillName, sourceDigest));

            if (Directory.Exists(destinationSkill))
            {
                if (existingMarker is null)
                {
                    backupPath = Path.Combine(
                        backupRoot,
                        skillName,
                        DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfffZ"));
                    Directory.CreateDirectory(Path.GetDirectoryName(backupPath)!);
                    Directory.Move(destinationSkill, backupPath);
                }
                else
                {
                    Directory.Move(destinationSkill, replacedRoot);
                }
            }

            try
            {
                Directory.Move(stagingRoot, destinationSkill);
            }
            catch
            {
                if (Directory.Exists(replacedRoot) && !Directory.Exists(destinationSkill))
                    Directory.Move(replacedRoot, destinationSkill);
                else if (backupPath is not null && Directory.Exists(backupPath) && !Directory.Exists(destinationSkill))
                    Directory.Move(backupPath, destinationSkill);
                throw;
            }

            if (Directory.Exists(replacedRoot))
                Directory.Delete(replacedRoot, recursive: true);

            return new SkillSyncResult(true, backupPath);
        }
        finally
        {
            if (Directory.Exists(stagingRoot))
                Directory.Delete(stagingRoot, recursive: true);
            if (Directory.Exists(replacedRoot))
                Directory.Delete(replacedRoot, recursive: true);
        }
    }

    private static void CopyTree(string sourceRoot, string destinationRoot)
    {
        foreach (var source in Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories))
        {
            var relativePath = Path.GetRelativePath(sourceRoot, source);
            if (Path.IsPathRooted(relativePath) || relativePath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Contains(".."))
                throw new InvalidDataException($"Bundled skill path escapes its source root: {relativePath}");

            var destination = Path.GetFullPath(Path.Combine(destinationRoot, relativePath));
            var root = Path.GetFullPath(destinationRoot) + Path.DirectorySeparatorChar;
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException($"Bundled skill path escapes its destination root: {relativePath}");

            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination, overwrite: false);
        }
    }

    private static string ComputeTreeDigest(string sourceRoot)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var source in Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories)
                     .Where(path => !string.Equals(Path.GetFileName(path), ManagedMarkerFile, StringComparison.OrdinalIgnoreCase))
                     .Order(StringComparer.Ordinal))
        {
            var relativePath = Path.GetRelativePath(sourceRoot, source).Replace('\\', '/');
            hash.AppendData(System.Text.Encoding.UTF8.GetBytes(relativePath));
            hash.AppendData([0]);
            hash.AppendData(File.ReadAllBytes(source));
            hash.AppendData([0]);
        }

        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static ManagedSkillMarker? ReadMarker(string markerPath)
    {
        try
        {
            return File.Exists(markerPath)
                ? JsonSerializer.Deserialize<ManagedSkillMarker>(File.ReadAllText(markerPath))
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static void WriteMarker(string skillRoot, ManagedSkillMarker marker)
        => File.WriteAllText(
            Path.Combine(skillRoot, ManagedMarkerFile),
            JsonSerializer.Serialize(marker, new JsonSerializerOptions { WriteIndented = true }));

    internal sealed record BundledSkillSyncResult(int Synchronized, int Unchanged, IReadOnlyList<string> BackupPaths);
    private sealed record SkillSyncResult(bool Changed, string? BackupPath);
    private sealed record ManagedSkillMarker(string SkillName, string Digest);
}
