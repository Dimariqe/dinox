using Gee;
using Gdk;
using Gtk;

using Dino.Entities;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/github/rallep71/DinoX/file_send_overlay.ui")]
public class FileSendOverlay : Adw.Dialog {

    public signal void send_file(File file);
    public signal void send_bytes(uint8[] data, string file_name, string mime_type);

    [GtkChild] protected unowned Button send_button;
    [GtkChild] protected unowned SizingBin file_widget_insert;
    [GtkChild] protected unowned Label info_label;

    private File? file = null;
    private uint8[]? bytes_data = null;
    private string? bytes_file_name = null;
    private string? bytes_mime_type = null;
    private bool can_send = true;

    // Constructor for a regular file on disk.
    public FileSendOverlay(File file, FileInfo file_info) {
        this.file = file;
        load_file_widget.begin(file, file_info);
    }

    // Constructor for in-memory image data (e.g. clipboard paste).
    // Shows a preview directly from the texture without writing to disk.
    public FileSendOverlay.from_texture(Gdk.Texture texture, string file_name, string mime_type, int64 byte_size) {
        this.bytes_file_name = file_name;
        this.bytes_mime_type = mime_type;

        // Encode to PNG bytes for both preview and sending.
        uint8[]? png = texture_to_png_bytes(texture);
        if (png != null) {
            this.bytes_data = png;
        }

        load_texture_preview(texture, file_name, mime_type, byte_size);
    }

    [GtkCallback]
    private void on_send_button_clicked() {
        if (file != null) {
            send_file((!)file);
        } else if (bytes_data != null) {
            send_bytes((!)bytes_data, bytes_file_name ?? "image.png", bytes_mime_type ?? "image/png");
        }
        close();
    }

    private async void load_file_widget(File file, FileInfo file_info) {
        string file_name = file_info.get_display_name();
        string mime_type = Dino.normalize_mime_type(file_info.get_content_type(), file_name);

        bool is_image = Dino.Util.is_pixbuf_supported_mime_type(mime_type);

        Widget? widget = null;
        if (is_image) {
            FileImageWidget image_widget = new FileImageWidget();
            try {
                yield image_widget.load_from_file(file, file_name);
                widget = image_widget;
            } catch (Error e) {
                warning("FileSendOverlay: Failed to load image preview for %s: %s", file_name, e.message);
            }
        }

        if (widget == null) {
            FileDefaultWidget default_widget = new FileDefaultWidget();
            default_widget.name_label.label = file_name;
            default_widget.set_static_file_info(mime_type);
            widget = default_widget;
        }

        widget.set_parent(file_widget_insert);
    }

    private void load_texture_preview(Gdk.Texture texture, string file_name, string mime_type, int64 byte_size) {
        var picture = new Gtk.Picture.for_paintable(texture);
        picture.content_fit = Gtk.ContentFit.CONTAIN;
        picture.hexpand = true;
        picture.vexpand = true;
        picture.set_size_request(200, 200);
        picture.set_parent(file_widget_insert);
    }

    // Encode a Gdk.Texture to raw PNG bytes via Gdk.Pixbuf.
    private static uint8[]? texture_to_png_bytes(Gdk.Texture texture) {
        try {
            var pixbuf = Gdk.pixbuf_get_from_texture(texture);
            if (pixbuf == null) return null;
            uint8[]? buffer = null;
            ((!)pixbuf).save_to_bufferv(out buffer, "png", null, null);
            return buffer;
        } catch (Error e) {
            warning("FileSendOverlay: texture_to_png_bytes failed: %s", e.message);
            return null;
        }
    }

    public void set_file_too_large() {
        info_label.label= _("The file exceeds the server's maximum upload size.");
        Util.force_error_color(info_label);
        send_button.sensitive = false;
        can_send = false;
    }
}

}
