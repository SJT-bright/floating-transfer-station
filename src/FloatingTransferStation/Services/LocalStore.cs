using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using FloatingTransferStation.Models;

namespace FloatingTransferStation.Services;

public sealed record AppPaths(
    string DataDirectory,
    string BoardFile,
    string SettingsFile,
    string ImagesDirectory)
{
    public static AppPaths CreateDefault(IDataDirectorySettings? settings = null)
    {
        var dataDirectory = DataDirectorySettings.NormalizeManagedDataDirectory(
            (settings ?? new WindowsDataDirectorySettings()).ReadDataDirectory())
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                ProductIdentity.DisplayName,
                "Data");
        return FromDataDirectory(dataDirectory);
    }

    public static AppPaths ForTests(string dataDirectory) => FromDataDirectory(dataDirectory);

    private static AppPaths FromDataDirectory(string dataDirectory) => new(
        dataDirectory,
        Path.Combine(dataDirectory, "board.json"),
        Path.Combine(dataDirectory, "settings.json"),
        Path.Combine(dataDirectory, "images"));
}

public sealed class LocalStore : IBoardStore
{
    private readonly AppPaths _paths;
    private readonly IAtomicTextWriter _writer;
    private readonly TimeProvider _timeProvider;
    private readonly SemaphoreSlim _boardWriteGate = new(1, 1);
    private readonly SemaphoreSlim _settingsWriteGate = new(1, 1);
    private volatile bool _boardWritesBlocked;
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter() }
    };

    public LocalStore(
        AppPaths paths,
        IAtomicTextWriter writer,
        TimeProvider? timeProvider = null)
    {
        _paths = paths;
        _writer = writer;
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public string ImagesDirectory => _paths.ImagesDirectory;
    public string? BoardLoadWarning { get; private set; }

    public async Task<BoardSnapshot> LoadBoardAsync(CancellationToken cancellationToken = default)
    {
        _boardWritesBlocked = false;
        BoardLoadWarning = null;
        var snapshot = await LoadBoardSnapshotAsync(cancellationToken).ConfigureAwait(false);
        if (snapshot.SchemaVersion != BoardSnapshot.CurrentSchemaVersion)
        {
            _boardWritesBlocked = true;
            BoardLoadWarning ??= "看板数据版本不受当前应用支持；原文件已保护，请使用兼容版本打开。";
            return new BoardSnapshot();
        }

        var clean = new BoardSnapshot();
        var seenIds = new HashSet<Guid>();
        foreach (var item in snapshot.Items ?? [])
        {
            if (!IsValidBaseItem(item) || !seenIds.Add(item.Id))
            {
                continue;
            }

            if (item.Kind == BoardItemKind.Text)
            {
                if (!string.IsNullOrWhiteSpace(item.Text))
                {
                    clean.Items.Add(item);
                }

                continue;
            }

            if (string.IsNullOrWhiteSpace(item.ImageRelativePath))
            {
                continue;
            }

            try
            {
                var absolutePath = ResolveImagePath(item.ImageRelativePath);
                if (File.Exists(absolutePath))
                {
                    item.ImageAbsolutePath = absolutePath;
                    clean.Items.Add(item);
                }
            }
            catch (InvalidDataException)
            {
                // Invalid entries are omitted while the rest of the board remains usable.
            }
        }

        return clean;
    }

    public async Task SaveBoardAsync(
        BoardSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        await _boardWriteGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_boardWritesBlocked)
            {
                throw new IOException(BoardLoadWarning ?? "看板处于只读保护状态，未写入新内容。");
            }

            if (File.Exists(_paths.BoardFile))
            {
                BoardSnapshot existing;
                try
                {
                    existing = await ReadBoardSnapshotAsync(_paths.BoardFile, cancellationToken)
                        .ConfigureAwait(false);
                }
                catch (JsonException)
                {
                    _boardWritesBlocked = true;
                    BoardLoadWarning = "看板文件无法读取，已停止写入以保护原数据。";
                    throw new IOException(BoardLoadWarning);
                }

                if (existing.SchemaVersion != BoardSnapshot.CurrentSchemaVersion)
                {
                    _boardWritesBlocked = true;
                    BoardLoadWarning = "看板数据版本不受当前应用支持；原文件已保护，未覆盖。";
                    throw new IOException(BoardLoadWarning);
                }
            }

            await _writer.WriteAsync(
                _paths.BoardFile,
                JsonSerializer.Serialize(snapshot, _jsonOptions),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _boardWriteGate.Release();
        }
    }

    private async Task<BoardSnapshot> LoadBoardSnapshotAsync(CancellationToken cancellationToken)
    {
        var backupPath = _paths.BoardFile + ".bak";
        var primaryWasCorrupt = false;
        if (File.Exists(_paths.BoardFile))
        {
            try
            {
                var primary = await ReadBoardSnapshotAsync(_paths.BoardFile, cancellationToken)
                    .ConfigureAwait(false);
                if (primary.SchemaVersion != BoardSnapshot.CurrentSchemaVersion)
                {
                    _boardWritesBlocked = true;
                    BoardLoadWarning = "看板由其他版本创建，当前应用不会写入以免覆盖原内容。";
                    return new BoardSnapshot();
                }
                return primary;
            }
            catch (JsonException)
            {
                PreserveCorruptFile(_paths.BoardFile);
                primaryWasCorrupt = true;
            }
            catch (IOException)
            {
                throw;
            }
        }

        if (File.Exists(backupPath))
        {
            try
            {
                var backup = await ReadBoardSnapshotAsync(backupPath, cancellationToken)
                    .ConfigureAwait(false);
                if (backup.SchemaVersion != BoardSnapshot.CurrentSchemaVersion)
                {
                    _boardWritesBlocked = true;
                    BoardLoadWarning = "看板备份由其他版本创建；原文件已保护，当前应用不会写入。";
                    return new BoardSnapshot();
                }
                if (primaryWasCorrupt)
                {
                    _boardWritesBlocked = true;
                    BoardLoadWarning = "主看板文件损坏，已从备份读取；当前处于只读保护状态，原文件和备份均已保留。";
                }
                return backup;
            }
            catch (JsonException)
            {
                _boardWritesBlocked = true;
                BoardLoadWarning = "看板文件或备份无法读取，已停止写入以保护原数据。";
                return new BoardSnapshot();
            }
        }

        if (primaryWasCorrupt)
        {
            _boardWritesBlocked = true;
            BoardLoadWarning = "看板文件损坏且没有可用备份，已停止写入以保护原数据。";
        }
        return new BoardSnapshot();
    }

    private async Task<BoardSnapshot> ReadBoardSnapshotAsync(
        string path,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var snapshot = await JsonSerializer.DeserializeAsync<BoardSnapshot>(
            stream,
            _jsonOptions,
            cancellationToken).ConfigureAwait(false);
        if (snapshot is null || snapshot.Items is null)
        {
            throw new JsonException("Board snapshot is empty or missing its items collection.");
        }
        return snapshot;
    }

    public Task<WindowSettings> LoadSettingsAsync(CancellationToken cancellationToken = default) =>
        LoadWithBackupAsync(_paths.SettingsFile, () => WindowSettings.Default, cancellationToken);

    public async Task SaveSettingsAsync(
        WindowSettings settings,
        CancellationToken cancellationToken = default)
    {
        await _settingsWriteGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _writer.WriteAsync(
                _paths.SettingsFile,
                JsonSerializer.Serialize(settings, _jsonOptions),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _settingsWriteGate.Release();
        }
    }

    public bool TryDeleteImage(string? absolutePath)
    {
        if (absolutePath is null || string.IsNullOrWhiteSpace(absolutePath) || !File.Exists(absolutePath))
        {
            return true;
        }

        try
        {
            if (!IsManagedImagePath(absolutePath))
            {
                return false;
            }

            File.Delete(absolutePath);
            return true;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private async Task<T> LoadWithBackupAsync<T>(
        string primaryPath,
        Func<T> fallback,
        CancellationToken cancellationToken)
    {
        if (File.Exists(primaryPath))
        {
            try
            {
                return await ReadAsync<T>(primaryPath, fallback, cancellationToken).ConfigureAwait(false);
            }
            catch (JsonException)
            {
                PreserveCorruptFile(primaryPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }
        }

        try
        {
            return await ReadAsync(primaryPath + ".bak", fallback, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
        {
            return fallback();
        }
    }

    private async Task<T> ReadAsync<T>(
        string path,
        Func<T> fallback,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            return fallback();
        }

        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return await JsonSerializer.DeserializeAsync<T>(stream, _jsonOptions, cancellationToken).ConfigureAwait(false)
               ?? fallback();
    }

    private string ResolveImagePath(string relativePath)
    {
        var normalizedRelative = relativePath.Replace('/', Path.DirectorySeparatorChar);
        var fullPath = Path.GetFullPath(Path.Combine(_paths.DataDirectory, normalizedRelative));
        if (!IsManagedImagePath(fullPath))
        {
            throw new InvalidDataException("Image path is outside the managed images directory.");
        }

        return fullPath;
    }

    private bool IsManagedImagePath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var allowedRoot = Path.GetFullPath(_paths.ImagesDirectory)
            .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return fullPath.StartsWith(allowedRoot, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsValidBaseItem(BoardItem? item) =>
        item is not null &&
        item.Id != Guid.Empty &&
        BoardCategoryCatalog.IsDefined(item.Category) &&
        item.Order >= 0 &&
        Enum.IsDefined(item.Kind);

    private void PreserveCorruptFile(string path)
    {
        if (!File.Exists(path))
        {
            return;
        }

        var timestamp = _timeProvider.GetUtcNow().ToString("yyyyMMddHHmmssfff");
        try
        {
            File.Copy(path, $"{path}.corrupt-{timestamp}-{Guid.NewGuid():N}.bak", overwrite: false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Recovery continues even if preserving the corrupt copy is temporarily impossible.
        }
    }
}
