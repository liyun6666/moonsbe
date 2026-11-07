import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;

/** Pins the bytes of the independently downloaded reference compiler. */
public final class ToolChecksum {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ToolChecksum sbe-all-1.35.0.jar");
        }
        String actual = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
            .digest(Files.readAllBytes(Path.of(args[0]))));
        String expected = "d11f4bb7c71322e3538613b2da18b11625be400465b29a09db80bc9785cea3ab";
        if (!actual.equals(expected)) {
            throw new AssertionError("reference compiler checksum mismatch " + actual);
        }
        System.out.println("Reference compiler checksum verified " + actual);
    }
}
