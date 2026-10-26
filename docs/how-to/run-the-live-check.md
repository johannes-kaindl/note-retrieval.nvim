# How-to: run the live check

The test suite (`make check`) never calls a real server. `make live` is one run against a real embedding server, for a developer who wants to see the whole path work: it is not part of `make check`.

## Run it

Both variables are required (an embedding index is tied to one model, so there is no default for it):

```bash
NOTE_RETRIEVAL_LIVE_URL=http://localhost:1234 NOTE_RETRIEVAL_LIVE_MODEL=<embedding model> make live
```

`NOTE_RETRIEVAL_LIVE_URL` is the address of the server (Ollama `http://localhost:11434`, LM Studio `http://localhost:1234`); `NOTE_RETRIEVAL_LIVE_MODEL` is the name of an embedding model it serves.

## What it does

It copies the fixture vault `tests/fixtures/vault/` (twenty small notes in five topics) into a scratch directory, embeds it into an own index there, asks for the notes related to `Baking/hydration.md`, and runs the self-find probe on 6 notes. Nothing outside the scratch directory is written.

- Pass: at least one of the related notes comes from the same topic (`Baking/`). The probe result is shown in the summary line but not asserted.

## Exit codes

The last line is `live: exit N`:

| Code | Meaning |
|---|---|
| 0 | Pass. |
| 1 | A check failed. |
| 2 | Nothing was measured: a variable is unset or empty, no server answered, or nothing was embedded. `make` itself exits 2 for any non-zero code. |

Without the variables it prints `live: nothing measured: set NOTE_RETRIEVAL_LIVE_URL (server address) and NOTE_RETRIEVAL_LIVE_MODEL (embedding model) first` and exits 2.
