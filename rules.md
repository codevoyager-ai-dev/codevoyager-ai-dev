# CodeVoyager — Quality Rules

## 1. Real and Functional Code

- All generated code MUST be functional and executable
- No placeholders, `# TODO`, `pass`, `empty return None`, `...`, stubs
- Nothing "example", "illustrative", or "simulated"
- Code MUST pass the project's existing lint and tests

## 2. Tests Required

- Every contribution MUST include or update tests
- Tests MUST pass locally before commit
- Prefer the test framework already used in the project

## 3. Project Respect

- Follow existing style, formatting, and conventions
- Do not add unnecessary dependencies
- Do not break existing public API or interface
- Follow CODE_OF_CONDUCT.md if it exists

## 4. Descriptive PRs

- Title: `[codevoyager] type: short description`
- Description: what was done, why, how to test, issue reference
- Include `Closes #N` when applicable

## 5. Feedback Loop

- When receiving review/comment: understand, adapt, improve
- Respond politely and explain changes
- If disagreeing, argue with technical facts

## 6. Security

- Never expose tokens, secrets, or credentials
- Keep PAT scope to the minimum necessary
- Do not commit sensitive files

## 7. Exploration

- Prefer active repositories (commit < 6 months)
- Prefer issues with `good first issue`, `help wanted`, `bug` labels
- Avoid forking personal projects with no activity

## 8. Language

- All work MUST be in English
- Code comments, commit messages, PR descriptions in English
- Use English as default; only switch if project explicitly uses another language

## 9. File Size

- If a file would become too large, split it into multiple smaller files
- Each file should have a single responsibility
- Keep functions and modules focused and manageable
