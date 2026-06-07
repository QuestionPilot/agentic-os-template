# Security And Secrets

Keep this repository free of secrets and machine-specific private state.

Do not store:

- API keys
- tokens
- OAuth files
- cookies
- private keys
- passwords
- local auth state
- raw browser profiles
- screenshots or traces that may expose private data
- machine-specific absolute paths in agnostic framework files

Use local untracked config for environment-specific values. Templates may include placeholder names, but never real credentials.
