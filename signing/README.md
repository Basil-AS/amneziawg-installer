# signing/

Detached minisign signatures for the current release, one `<script>.minisig`
per signed file.

These files are **transient**. They are produced on the maintainer's machine
immediately before a tag, committed so they land in the tagged commit, and left
in place until the next release replaces them. They are deliberately **not**
gitignored: `release.yml` checks out the tag and refuses to publish without
them.

## Why the signing does not happen in CI

The private key never reaches GitHub Actions. That is the entire point of the
scheme: a signature produced by CI would prove only that CI ran, which is
already what a GitHub Release proves. A signature produced offline proves that
the holder of a key that has never touched the network approved these exact
bytes.

## Producing them for a release

The next prepared release is `v5.29.0`. Run these commands from the
release commit, using the existing private key that matches the public key in
`KEYS.txt`. Never copy the private key into the repository, a GitHub secret, or
this chat.

```bash
TAG=v5.29.0                                    # the tag about to be pushed
KEY=~/.minisign/amneziawg-installer.key
mkdir -p signing
while IFS= read -r f; do
  minisign -Sm "$f" -s "$KEY" -x "signing/$f.minisig" \
           -t "amneziawg-installer $TAG $f"
done < <(bash scripts/signed-file-list.sh)
bash scripts/verify-signatures.sh "$TAG"      # confirm before committing
```

If the key is stored elsewhere, set `KEY` to that local path. If minisign
reports a public-key mismatch, stop: do not replace `KEYS.txt` and do not
generate a new key as a workaround. Ask the maintainer to confirm the trust
root first.

After verification, commit the six files under `signing/` in a PR, let CI
finish, merge the PR, and only then create and push the matching tag:

```bash
git tag -a v5.29.0 -m "AmneziaWG installer v5.29.0"
git push origin v5.29.0
```

The tag starts the release workflow. This fork keeps signature verification
available but does not require it for ordinary GitHub Releases because the
upstream private key is not available here. Set `REQUIRE_RELEASE_SIGNATURES=true`
in the workflow environment to restore the verification gate.

The `-t` trusted comment is not decoration. A signature proves that some bytes
were signed, not that they were signed *for this release*: an old file with its
own old signature verifies perfectly well. Binding the comment to tag and
filename is what makes a rollback or a swapped file detectable, and
`verify-signatures.sh` fails if the comment does not name the expected tag.

## Verifying as a user

Everything needed is attached to each release, so nothing has to be trusted
from a second place at verification time:

```bash
minisign -V -p KEYS.txt -m install_amneziawg.sh -x install_amneziawg.sh.minisig
```

⚠️ Fetching `KEYS.txt` from this repository in the same session as the script
gives no protection against a compromise of the repository itself - an attacker
able to replace one can replace all three. The key is worth pinning once from a
source outside GitHub and reusing it afterwards; that is what turns the
signature into a real check rather than a ritual.
