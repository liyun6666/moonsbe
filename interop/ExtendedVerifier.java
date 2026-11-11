/*
 * Copyright 2026 Ma Yunyun
 * Licensed under the Apache License, Version 2.0.
 */
import extended.ExtendedDecoder;
import extended.ExtendedDimensionsEncoder;
import extended.ExtendedEncoder;
import extended.ExtendedHeaderDecoder;
import extended.ExtendedHeaderEncoder;
import org.agrona.concurrent.UnsafeBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

/** Independent wire oracle generated from extended-schema.xml by SbeTool. */
public final class ExtendedVerifier {
    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            throw new IllegalArgumentException("usage: ExtendedVerifier emit|verify present|null FILE.bin");
        }
        boolean absent = switch (args[1]) {
            case "present" -> false;
            case "null" -> true;
            default -> throw new IllegalArgumentException(args[1]);
        };
        var path = Path.of(args[2]);
        byte[] expected = encode(absent);
        switch (args[0]) {
            case "emit" -> Files.write(path, expected);
            case "verify" -> {
                byte[] actual = Files.readAllBytes(path);
                int mismatch = Arrays.mismatch(expected, actual);
                require(mismatch == -1, "wire mismatch at byte " + mismatch);
                decode(actual, absent);
            }
            default -> throw new IllegalArgumentException(args[0]);
        }
        System.out.println("EXTENDED PASS " + args[0] + " " + args[1] + " bytes=" + expected.length);
    }

    private static byte[] encode(boolean absent) {
        var buffer = new UnsafeBuffer(new byte[128]);
        var header = new ExtendedHeaderEncoder();
        var encoder = new ExtendedEncoder().wrapAndApplyHeader(buffer, 0, header);
        header.numGroups((short)1).numVarDataFields((short)1);
        encoder.sequence(0x01020304L);
        encoder.price().mantissa(absent ? -99 : 1250)
            .exponent((byte)(absent ? 0 : -2)).quality((short)(absent ? 0 : 8));
        encoder.status(absent ? 65535 : 123);
        int dimensionsOffset = encoder.limit();
        encoder.rowsCount(1).next().code(42).label("x");
        // The upstream group writer sets blockLength and numInGroup.
        // Set the spec's additional counts through the generated dimensions.
        new ExtendedDimensionsEncoder().wrap(buffer, dimensionsOffset)
            .numGroups((short)0).numVarDataFields((short)1);
        encoder.note("ok");
        return Arrays.copyOf(buffer.byteArray(), encoder.limit());
    }

    private static void decode(byte[] bytes, boolean absent) {
        var buffer = new UnsafeBuffer(bytes);
        var header = new ExtendedHeaderDecoder().wrap(buffer, 0);
        require(header.blockLength() == 12 && header.version() == 1
            && header.numGroups() == 1 && header.numVarDataFields() == 1, "extended header");
        var decoder = new ExtendedDecoder().wrapAndApplyHeader(buffer, 0, header);
        require(decoder.sequence() == 0x01020304L, "sequence");
        require(decoder.price().mantissa() == (absent ? -99 : 1250), "price mantissa");
        require(decoder.price().exponent() == (absent ? 0 : -2), "price exponent");
        require(decoder.price().quality() == (absent ? 0 : 8), "price quality");
        require(decoder.status() == (absent ? 65535 : 123), "optional status");
        var rows = decoder.rows();
        require(rows.count() == 1, "row count");
        require(rows.next().code() == 42 && "x".equals(rows.label()), "row payload");
        require("ok".equals(decoder.note()), "note");
        require(decoder.encodedLength() + ExtendedHeaderDecoder.ENCODED_LENGTH == bytes.length,
            "complete message consumed");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
