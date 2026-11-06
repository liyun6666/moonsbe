/*
 * Copyright 2026 Ma Yunyun
 * Licensed under the Apache License, Version 2.0.
 */
package uk.co.real_logic.sbe.examples;

import baseline.CarDecoder;
import baseline.CarEncoder;
import baseline.MessageHeaderDecoder;
import baseline.MessageHeaderEncoder;
import org.agrona.concurrent.UnsafeBuffer;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HexFormat;

/** Uses the unmodified upstream example encoder and generated Java decoder. */
public final class ReferenceVerifier {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ReferenceVerifier MESSAGE.bin");
        }
        byte[] actual = Files.readAllBytes(Path.of(args[0]));
        ByteBuffer buffer = ByteBuffer.allocate(4096);
        UnsafeBuffer expectedBuffer = new UnsafeBuffer(buffer);
        int length = ExampleUsingGeneratedStub.encode(
            new CarEncoder(), expectedBuffer, new MessageHeaderEncoder());
        byte[] expected = Arrays.copyOf(buffer.array(), length);
        int mismatch = Arrays.mismatch(expected, actual);
        if (mismatch != -1) {
            throw new AssertionError("reference byte mismatch at " + mismatch
                + "; expected " + expected.length + " bytes, got " + actual.length);
        }
        UnsafeBuffer actualBuffer = new UnsafeBuffer(actual);
        MessageHeaderDecoder header = new MessageHeaderDecoder().wrap(actualBuffer, 0);
        if (header.schemaId() != 1 || header.templateId() != 1
                || header.version() != 0 || header.blockLength() != CarDecoder.BLOCK_LENGTH) {
            throw new AssertionError("incorrect SBE header");
        }
        CarDecoder decoder = new CarDecoder();
        // This is the upstream decoder's complete field traversal, including
        // variable data and nested repeating groups.
        ExampleUsingGeneratedStub.decode(decoder, actualBuffer, header);
        if (decoder.encodedLength() + MessageHeaderDecoder.ENCODED_LENGTH != actual.length) {
            throw new AssertionError("decoder did not consume the complete message");
        }
        String sha256 = HexFormat.of().formatHex(
            MessageDigest.getInstance("SHA-256").digest(actual));
        System.out.println("INTEROP PASS bytes=" + actual.length + " sha256=" + sha256);
    }
}
