using BotNexus.Cli.Commands;
using Shouldly;

namespace BotNexus.Cli.Tests.Commands;

public sealed class BundledSkillInstallerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"botnexus-bundled-skills-{Guid.NewGuid():N}");

    [Fact]
    public void Synchronize_CopiesManagedSkillsAndPreservesUnrelatedSkills()
    {
        var source = SourceRoot();
        WriteSkill(source, "botnexus-pr-execution", "source-pr");
        WriteSkill(source, "botnexus-backlog-grooming", "source-groom");
        WriteSkill(source, "unmanaged", "must-not-install");

        var home = HomeRoot();
        WriteSkill(Path.Combine(home, "skills"), "personal-skill", "personal");

        var result = BundledSkillInstaller.Synchronize(source, home);

        result.Synchronized.ShouldBe(2);
        result.BackupPaths.Count.ShouldBe(0);
        File.ReadAllText(Path.Combine(home, "skills", "botnexus-pr-execution", "SKILL.md")).ShouldBe("source-pr");
        File.ReadAllText(Path.Combine(home, "skills", "botnexus-backlog-grooming", "SKILL.md")).ShouldBe("source-groom");
        File.ReadAllText(Path.Combine(home, "skills", "personal-skill", "SKILL.md")).ShouldBe("personal");
        Directory.Exists(Path.Combine(home, "skills", "unmanaged")).ShouldBeFalse();
    }

    [Fact]
    public void Synchronize_UpdatesManagedDirectoryAndRemovesDeletedFiles()
    {
        var source = SourceRoot();
        WriteSkill(source, "botnexus-pr-execution", "first");
        var home = HomeRoot();
        BundledSkillInstaller.Synchronize(source, home);

        File.WriteAllText(Path.Combine(home, "skills", "botnexus-pr-execution", "stale.txt"), "stale");
        WriteSkill(source, "botnexus-pr-execution", "second");
        var sourceScript = Path.Combine(source, "botnexus-pr-execution", "scripts", "run.ps1");
        Directory.CreateDirectory(Path.GetDirectoryName(sourceScript)!);
        File.WriteAllText(sourceScript, "new-script");

        var result = BundledSkillInstaller.Synchronize(source, home);

        result.Synchronized.ShouldBe(1);
        File.ReadAllText(Path.Combine(home, "skills", "botnexus-pr-execution", "SKILL.md")).ShouldBe("second");
        File.ReadAllText(Path.Combine(home, "skills", "botnexus-pr-execution", "scripts", "run.ps1")).ShouldBe("new-script");
        File.Exists(Path.Combine(home, "skills", "botnexus-pr-execution", "stale.txt")).ShouldBeFalse();
    }

    [Fact]
    public void Synchronize_BacksUpUnmanagedSameNameDirectoryBeforeAdoption()
    {
        var source = SourceRoot();
        WriteSkill(source, "botnexus-pr-execution", "managed");
        var home = HomeRoot();
        WriteSkill(Path.Combine(home, "skills"), "botnexus-pr-execution", "local-unmanaged");

        var result = BundledSkillInstaller.Synchronize(source, home);

        result.Synchronized.ShouldBe(1);
        result.BackupPaths.Count.ShouldBe(1);
        File.ReadAllText(Path.Combine(result.BackupPaths[0], "SKILL.md")).ShouldBe("local-unmanaged");
        File.ReadAllText(Path.Combine(home, "skills", "botnexus-pr-execution", "SKILL.md")).ShouldBe("managed");
    }

    [Fact]
    public void Synchronize_IsIdempotentForIdenticalManagedContent()
    {
        var source = SourceRoot();
        WriteSkill(source, "botnexus-pr-execution", "same");
        var home = HomeRoot();

        BundledSkillInstaller.Synchronize(source, home);
        var destination = Path.Combine(home, "skills", "botnexus-pr-execution", "SKILL.md");
        var sentinelWriteTime = new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(destination, sentinelWriteTime);

        var result = BundledSkillInstaller.Synchronize(source, home);

        result.Synchronized.ShouldBe(0);
        result.Unchanged.ShouldBe(1);
        File.GetLastWriteTimeUtc(destination).ShouldBe(sentinelWriteTime);
    }

    [Fact]
    public void Synchronize_SkipsManagedSkillWhenSourceIsAbsent()
    {
        var source = SourceRoot();
        WriteSkill(source, "botnexus-pr-execution", "present");
        var home = HomeRoot();

        BundledSkillInstaller.Synchronize(source, home).Synchronized.ShouldBe(1);
        Directory.Exists(Path.Combine(home, "skills", "botnexus-backlog-grooming")).ShouldBeFalse();
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
            Directory.Delete(_root, recursive: true);
    }

    private string SourceRoot() => Path.Combine(_root, "source");
    private string HomeRoot() => Path.Combine(_root, "home");

    private static void WriteSkill(string root, string name, string content)
    {
        var directory = Path.Combine(root, name);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "SKILL.md"), content);
    }
}
