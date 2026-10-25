# Public qualification evidence

`trusted-verifier export-public` derives `qualification-public.json` from an
accepted signed private bundle and the final executable plus both existing
release archives. It reuses the operator's existing qualification signing key.
The private bundle and public directory must be separate, without either
containing the other. An existing public evidence file is never overwritten.

The public file authenticates source/version/axis, the executable and archive
digests, archive executable membership, case dispositions, waiver metadata and
the private evidence inventory's digests. Raw requests/readbacks, filesystem
paths, case/run identifiers and waiver impact text remain private. Their hashes
retain the binding. Waived cases do not become positively qualified operations.

After the normal final-artifact/source-member verification succeeds, the trusted
operator can export the public representation:

```sh
bash Scripts/release-consume-final.sh verify "$VERSION" "$COMMIT" \
  "$CANDIDATE" "$PRIVATE_BUNDLE" "$TRUSTED_VERIFIER" "$PUBLIC_DIRECTORY"
"$TRUSTED_VERIFIER" export-public --candidate "$CANDIDATE" \
  --bundle "$PRIVATE_BUNDLE" --public-directory "$PUBLIC_DIRECTORY" \
  --release-version "$VERSION" --expected-commit "$COMMIT"
```

Export requires `LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY`, as the existing trusted
signing command does. Signing material is not supplied by the candidate/bundle
and is not forwarded to the isolated archive parser. Export itself does not
upload files or activate a release. The normal release source-member/install
checks remain necessary; export's archive check establishes the executable
member and safe regular-member structure, rather than source equality for every
companion file.

An external consumer retrieves the public evidence file, `LogicProMCP` and both
archives, then runs an independently trusted verifier build:

```sh
LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY="$AUTHENTICATED_PUBLIC_KEY" \
  "$TRUSTED_VERIFIER" verify-public --public-directory "$DOWNLOADED_FILES" \
  --release-version "$VERSION" --expected-commit "$COMMIT" \
  --expected-axis desktop/en-US/core/cold/empty
```

The key comes from an independently authenticated channel, not those downloaded
files. A successful command prints authenticated metadata and verifies the
actual public file digests. It does not replay private semantic evidence.
Changing a file and its neighboring checksum cannot replace the signature.
This provides authenticity and tamper detection under the trusted signer/key
assumption, rather than storage immutability. Actual publication, public key
distribution and unauthenticated retrieval remain separate release steps.
