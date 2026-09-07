"""A private local code-signing identity for repeatable Hush updates.

No certificate is added to system trust. The dedicated keychain is kept in
this checkout's ignored .runtime directory.
"""
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
folder = root / ".runtime/signing"
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(folder, 0o700)
config_path = folder / "identity.json"


def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result.stdout


def create_identity():
    password = secrets.token_urlsafe(36)
    password_file = folder / "password"
    password_file.write_text(password)
    password_file.chmod(0o600)
    keychain = folder / "Hush-signing.keychain-db"
    name = "Hush Local Development"
    openssl_config = folder / "certificate.cnf"
    openssl_config.write_text("""[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Hush Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
    key = folder / "temporary-key.pem"
    certificate = folder / "certificate.pem"
    archive = folder / "temporary-identity.p12"
    original_search_list = shlex.split(run(["security", "list-keychains", "-d", "user"]))
    try:
        run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:3072", "-x509", "-sha256", "-days", "3650",
             "-nodes", "-config", str(openssl_config), "-keyout", str(key), "-out", str(certificate)])
        key.chmod(0o600)
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
             "-name", name, "-out", str(archive), "-passout", "file:" + str(password_file)])
        archive.chmod(0o600)
        run(["security", "create-keychain", "-p", password, str(keychain)])
        run(["security", "unlock-keychain", "-p", password, str(keychain)])
        run(["security", "set-keychain-settings", "-lut", "300", str(keychain)])
        run(["security", "import", str(archive), "-k", str(keychain), "-P", password, "-x", "-T", "/usr/bin/codesign"])
        run(["security", "set-key-partition-list", "-S", "apple-tool:,codesign:", "-s", "-k", password, str(keychain)])
        fingerprint = run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1"]).strip().split("=")[-1].replace(":", "")
        config_path.write_text(json.dumps({"identity": fingerprint, "keychain": str(keychain), "password_file": str(password_file)}))
        config_path.chmod(0o600)
        run(["security", "lock-keychain", str(keychain)])
    finally:
        run(["security", "list-keychains", "-d", "user", "-s", *original_search_list])
        key.unlink(missing_ok=True)
        archive.unlink(missing_ok=True)
    print("Created Hush's private local signing identity. No system certificate trust was changed.")


if len(sys.argv) == 2 and sys.argv[1] == "--create":
    if config_path.exists():
        print("Hush's local signing identity already exists.")
    else:
        create_identity()
elif len(sys.argv) == 2:
    config = json.loads(config_path.read_text())
    password = Path(config["password_file"]).read_text()
    run(["security", "unlock-keychain", "-p", password, config["keychain"]])
    try:
        run(["codesign", "--force", "--deep", "--keychain", config["keychain"],
             "--sign", config["identity"], str(Path(sys.argv[1]).resolve())])
        run(["codesign", "--verify", "--deep", "--strict", sys.argv[1]])
    finally:
        run(["security", "lock-keychain", config["keychain"]])
    print("Signed with Hush's persistent local identity.")
else:
    raise SystemExit("Usage: local-signing.py --create | PATH_TO_APP")
