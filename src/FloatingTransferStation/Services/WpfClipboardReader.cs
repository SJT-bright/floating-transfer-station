using System.Windows;
using System.Windows.Media.Imaging;
using System.Runtime.InteropServices;
using FloatingTransferStation.Models;

namespace FloatingTransferStation.Services;

public sealed class WpfClipboardReader : IClipboardReader
{
    private readonly WindowsDataImageReader _imageReader;

    public WpfClipboardReader()
        : this(new WindowsDataImageReader())
    {
    }

    internal WpfClipboardReader(WindowsDataImageReader imageReader)
    {
        _imageReader = imageReader;
    }

    public async Task<ClipboardSnapshot> ReadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var application = Application.Current
            ?? throw new InvalidOperationException("WPF application is not running.");
        var dispatcher = application.Dispatcher;
        if (!dispatcher.CheckAccess())
        {
            return await dispatcher.InvokeAsync(
                ReadNow,
                System.Windows.Threading.DispatcherPriority.Send,
                cancellationToken);
        }

        return ReadNow();
    }

    private ClipboardSnapshot ReadNow()
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var sequenceBefore = NativeMethods.GetClipboardSequenceNumber();
            var dataObject = Clipboard.GetDataObject();
            var imageCandidates = dataObject is null ? [] : _imageReader.ReadCandidates(dataObject);
            var image = imageCandidates.FirstOrDefault(candidate => candidate.IsBitmap)?.Bitmap;
            var encodedImages = imageCandidates.Where(candidate => !candidate.IsBitmap).ToArray();

            IReadOnlyList<string> files = Clipboard.ContainsFileDropList()
                ? Clipboard.GetFileDropList().Cast<string>().ToArray()
                : [];
            var text = Clipboard.ContainsText(TextDataFormat.UnicodeText)
                ? Clipboard.GetText(TextDataFormat.UnicodeText)
                : null;

            var sequenceAfter = NativeMethods.GetClipboardSequenceNumber();
            if (sequenceBefore == sequenceAfter)
            {
                return new ClipboardSnapshot(sequenceAfter, image, files, text, encodedImages);
            }
        }

        throw new ExternalException("The clipboard changed while its contents were being read.");
    }

}
