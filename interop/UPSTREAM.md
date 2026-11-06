# Pinned upstream reference

- Repository: https://github.com/aeron-io/simple-binary-encoding
- Tag: `1.35.0`
- Tag object: `29dc5cec8c30135fe19b4121be9d5f5f6ad1ad05`
- Tool artifact: https://repo.maven.apache.org/maven2/uk/co/real-logic/sbe-all/1.35.0/sbe-all-1.35.0.jar
- License: Apache License 2.0; see the repository LICENSE.

The files under `upstream/` are unmodified copies of these upstream paths:

- `sbe-samples/src/main/resources/example-schema.xml`
- `sbe-samples/src/main/resources/common-types.xml`
- `sbe-samples/src/main/java/uk/co/real_logic/sbe/examples/ExampleUsingGeneratedStub.java`

These files and generated Java code are reference material, excluded from
handwritten MoonBit implementation counts. `ReferenceVerifier.java` calls the
upstream example encoder to build independent expected bytes, compares every
byte, and traverses the incoming message with the upstream generated decoder.

The upstream tool version is not the SBE wire specification version. The
implemented wire profile is documented in `docs/compatibility.md`.
