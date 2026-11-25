# Week 5: LLM chat with CI/CD

A Flask chat app that talks to a local Ollama model and stores each conversation in MariaDB. GitHub Actions lints and tests every push and pull request, and deploys pushes to `main` to a cPouta server automatically.

- Chat: http://193.166.25.66/viikko5/
- Health: http://193.166.25.66/viikko5/health (returns the Git commit SHA that is running)

## Request path

browser -> Nginx (port 80, /viikko5/) -> Unix socket -> Gunicorn + Flask -> Ollama (127.0.0.1:11434) and MariaDB (127.0.0.1:3306)

## Layout

- app.py, db.py: the application
- test_app.py: pytest tests; Ollama and MariaDB are mocked
- templates/, static/: the web page
- deploy/nginx/chatapp.conf: Nginx snippet (location blocks only, no server block)
- deploy/systemd/chatapp.service: systemd unit, runs as the non-login user chatapp
- deploy/sql/schema.sql: database schema
- scripts/server-setup.sh: one-time server setup
- scripts/deploy.sh: run on the server by the workflow
- .github/workflows/ci-cd.yml: the pipeline

## Run locally

Create a virtual environment, run `pip install -r requirements-dev.txt`, then `ruff check .` and `pytest`. Without DB_NAME the app keeps messages in memory. `flask --app app run` starts it (real replies need a local Ollama).

## Set up the server (once)

1. Copy scripts/server-setup.sh to the server and run `bash server-setup.sh qwen2.5:0.5b`.
2. Add `include snippets/chatapp.conf;` inside the server block of the existing Nginx site, then run `sudo nginx -t && sudo systemctl reload nginx`.
3. Create a separate SSH key pair for GitHub Actions and add its public key to ~/.ssh/authorized_keys on the server.

## GitHub secrets

CPOUTA_HOST, CPOUTA_USER, CPOUTA_SSH_KEY (the private deploy key) and CPOUTA_KNOWN_HOSTS (the server's host key line). No secret is stored in this repository. The database password exists only in /etc/chatapp/chatapp.env on the server.

## Deployment

A push to main runs the tests; if they pass, the code is copied with rsync to /opt/chatapp/app and deploy.sh installs dependencies, applies the schema, updates the Nginx snippet (tested with nginx -t before reload) and restarts only the chatapp service. The workflow then requires /viikko5/health to return the commit SHA of the run and fails otherwise.