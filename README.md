# Jenkins Installation (dockerized) — Installer Script

This repository contains an interactive installer script that prepares a Docker-based Jenkins instance on a Linux host, builds a custom Jenkins image (with plugins and optional AWS CLI), and writes a docker-compose configuration to run Jenkins.

Primary script:
- `install_jenkins.sh`

This README explains the prerequisites, how the script works, supported options, the exact steps to run it, what files it creates, and troubleshooting tips so you can reproduce or customize the installation reliably.

---

Table of Contents
- Overview
- Prerequisites and supported platforms
- What the script does (high level)
- Files/directories created by the script
- Directory structure (visual)
- Environment & configuration variables you can edit
- Step-by-step installation / usage
- Starting and managing Jenkins
- Customization (plugins, shared libraries, AWS)
- Cleanup and teardown
- Troubleshooting
- Security notes
- Contributing / Contact

---

Overview
========
The installer script automates the following:
- Creates a directory structure for Jenkins, JCasC (Configuration as Code), secrets, SSH keys, and docker-compose.
- Optionally configures a Shared Library (Git) for Jenkins.
- Optionally adds AWS CLI into the Jenkins image.
- Checks/installs Docker (via yum) and docker-compose if missing.
- Writes `plugins.txt`, a `Dockerfile`, `entrypoint.sh`, JCasC YAML (`jenkins.yaml`), and `docker-compose.yml`.
- Guides you to build and run the Jenkins container via docker-compose.

It is intended for a Linux environment where you have sudo privileges and Docker is supported. The script is interactive and prompts you for required values (admin username/password, SSH private key, optional shared library and AWS options).

Prerequisites
=============
- A Linux host where `yum` is available (CentOS / RHEL / Amazon Linux family). The script uses `yum` to install Docker on the host.
- sudo privileges for installing packages and creating system users.
- Docker (the script can install/upgrade Docker using yum if missing).
- curl, unzip (the script installs them as needed).
- A modern Docker Engine and either the standalone `docker-compose` binary or the `docker compose` plugin. The script attempts to install docker-compose standalone if `docker-compose` CLI is missing.
- Port 8080 open on the host (Jenkins default).
- Enough filesystem space for Docker images and containers.

If your host uses a different package manager (apt/dpkg), you can still use the script but you will need to adapt the Docker installation steps manually; the script assumes `yum`.

What the script does (high level)
=================================
- Creates the layout under `$ROOT_DIR` (default `/projects/jenkins-installation`).
  - Jenkins files, `docker-compose` directory, Jenkins home, SSH dir and secrets.
- Creates a `jenkins` user/group on the host (UID/GID configurable in the script).
- Prompts and saves:
  - Jenkins admin username and password (admin password is saved to a secret file that the JCasC config reads)
  - SSH private key (copied into container-mounted host folder)
  - Optional Shared Library Git SSH URL, library name, credential id
  - Optional AWS CLI enablement for the Jenkins container
- Installs or upgrades Docker using the Docker CE repo (yum).
- Installs docker-compose standalone binary if not present.
- Writes:
  - `plugins.txt` (plugin list)
  - `entrypoint.sh` (container entrypoint that initializes AWS config if enabled)
  - `Dockerfile` (builds from `jenkins/jenkins:lts-jdk17`, installs docker cli and optionally awscli)
  - `casc/jenkins.yaml` (Jenkins Configuration as Code)
  - `docker-compose/docker-compose.yml` (service definition)
- Sets permissions and ownership so that the `jenkins` user (on host) owns the created directories where appropriate.

Files and directories created
=============================
Below are the important locations created by the script (default root is `/projects/jenkins-installation`):

- `jenkins/` — build context for the Jenkins Docker image:
  - `plugins.txt` — plugin list used during image build
  - `Dockerfile` — custom Jenkins Dockerfile
  - `entrypoint.sh` — extra entrypoint that initializes AWS config if enabled
  - `casc/jenkins.yaml` — Jenkins JCasC configuration
- `docker-compose/docker-compose.yml` — docker-compose file to build and run Jenkins
- `jenkins/jenkins_home/` — host directory mounted to container as `/var/jenkins_home`
  - `secrets/adminPassword` — admin password file created by the script
- `jenkins-ssh/` — host directory containing SSH private key and `known_hosts` (mounted read-only into the container)
- Host user/group `jenkins` (UID/GID default 2001) are created if missing.

Directory structure (visual)
============================
For convenience, here is an example of the directory layout the installer creates under the default `ROOT_DIR` (`/projects/jenkins-installation`). Replace `/projects/jenkins-installation` with your chosen `ROOT_DIR` if you changed it.

```datalex/jenkins-installation/README.md#L1-40
/projects/jenkins-installation/
├─ jenkins/                        # Docker build context and JCasC location
│  ├─ Dockerfile                   # Custom Jenkins Dockerfile (generated)
│  ├─ plugins.txt                  # Plugin list used at image build time
│  ├─ entrypoint.sh                # Optional entrypoint to initialize AWS config
│  └─ casc/
│     └─ jenkins.yaml              # Jenkins Configuration-as-Code (JCasC)
├─ docker-compose/
│  └─ docker-compose.yml           # Compose file to build and run local-jenkins
├─ jenkins-ssh/                     # Host SSH dir mounted into container (read-only)
│  ├─ id_rsa                        # Private key copied/pasted by the installer
│  └─ known_hosts                   # Populated from ssh-keyscan (bitbucket.org)
└─ jenkins/jenkins_home/            # Persistent Jenkins home mounted into container
   └─ secrets/
      └─ adminPassword              # Admin password file written by the installer
```

Notes on the tree
- `jenkins/` is the Docker build context used by the `docker-compose` service to build `local-jenkins:latest`.
- `jenkins-ssh/` is mounted read-only inside the container at `/var/jenkins_home/.ssh` and is the source for the SSH credential created via JCasC.
- `jenkins/jenkins_home` is the persistent Jenkins data directory — back this up if you need to preserve job history, artifacts, credentials, etc.

Configuration variables you can change in the script
===================================================
At the top of `install_jenkins.sh` you will find a few variables you may want to adjust:

- `ROOT_DIR` — default root path for all created directories (default: `/projects/jenkins-installation`)
- `JENKINS_UID`, `JENKINS_GID` — host UID/GID to assign `jenkins` user/group (default 2001)
- `CRED_ID` — default credential id to use for git ssh key inside JCasC (default `git-ssh-private-key`)
- `ENABLE_SHARED_LIBS` / `ENABLE_AWS` — feature flags toggled interactively by the script

Step-by-step installation
=========================
1. Clone this repo or copy the files to a machine where you want Jenkins installed.

2. Inspect the script before running:
   - Open `install_jenkins.sh` and review variable defaults (`ROOT_DIR`, UID/GID), and make any edits necessary for your environment.
   - Confirm that installing Docker with `yum` is appropriate for your host (CentOS/RHEL family).

3. Make the script executable and run it with sudo (the script itself uses `sudo` internally for the operations that require it). Example:
```datalex/jenkins-installation/README.md#L1-8
# from the repository root
chmod +x install_jenkins.sh
sudo ./install_jenkins.sh
```

4. Interactive prompts:
   - Shared library: you will be asked to enter Git SSH URL and library name. Leave blank to skip.
   - AWS: it will ask whether to enable AWS CLI and credentials inside Jenkins; reply `y` or `n`.
   - Docker upgrade: if the script detects Docker is installed but a newer version is available it will prompt whether to upgrade.
   - Jenkins admin username & password: required — the password is saved to `jenkins/jenkins_home/secrets/adminPassword`.
   - SSH private key: the script will attempt to copy keys from `~/.ssh` (non-public keys). You can select one or paste a private key to be written to `jenkins-ssh/id_rsa`.

5. Once the script completes it will print the exact next commands to build and start Jenkins (see "Starting Jenkins" below).

Starting Jenkins
================
Change directory into the generated docker-compose folder and build/up the service:

```datalex/jenkins-installation/README.md#L1-6
cd /projects/jenkins-installation/docker-compose
docker-compose build --no-cache
docker-compose up -d
```

Notes:
- If you use the newer Docker Compose plugin (`docker compose`), you can run:
```datalex/jenkins-installation/README.md#L1-3
docker compose build --no-cache
docker compose up -d
```
- Jenkins will be reachable at http://localhost:8080 (or at the host IP if accessed remotely and port 8080 is open).
- The initial admin user/password are created based on values provided to the installer (via the secret file).

Customizing the installation
============================
Plugins
- Edit `jenkins/plugins.txt` (the script will create it if missing). To add or remove plugins, update this file and rebuild the image:
```datalex/jenkins-installation/README.md#L1-4
cd /projects/jenkins-installation/jenkins
# edit plugins.txt
cd ../docker-compose
docker-compose build --no-cache
docker-compose up -d
```

JCasC (Jenkins Configuration as Code)
- The script writes `jenkins/casc/jenkins.yaml` with:
  - admin user and JCasC permissions
  - credentials section containing the `basicSSHUserPrivateKey` entry (reads private key from `/var/jenkins_home/.ssh/id_rsa` in the container)
  - optional `globalLibraries` block if you enabled shared libraries
- To change JCasC, edit `jenkins/casc/jenkins.yaml` before starting the container or modify it and restart the container so Jenkins picks up changes.

Shared Library (optional)
- If you answered the prompts and provided `GIT_SSH_URL` and `LIB_NAME`, the JCasC will include a `globalLibraries` entry.
- The `privateKey` used for the library is read from `/var/jenkins_home/.ssh/id_rsa` (provided via `jenkins-ssh` host directory).

AWS CLI inside Jenkins image (optional)
- If you enable AWS during the installer prompts:
  - The Docker build will install the AWS CLI into the Jenkins image.
  - The docker-compose file maps `/root/.aws/config` on the host into the container at `/aws-bootstrap/config` and the container entrypoint copies it into `/var/jenkins_home/.aws/config` (so you must ensure a proper AWS config exists on the host or provide one).
- If you enable AWS, ensure host file `/root/.aws/config` exists and contains appropriate credentials/configuration (or change the mapping in `docker-compose.yml` to another file you manage).

Permissions and ownership
- The script will create a `jenkins` group and user on the host if missing and chown the created `jenkins` directory tree to `jenkins:jenkins`.
- The container runs as `jenkins` user to match those permissions.

Cleanup / Tear down
===================
To stop and remove containers, networks and volumes created by docker-compose:
```datalex/jenkins-installation/README.md#L1-6
cd /projects/jenkins-installation/docker-compose
docker-compose down
# or
docker compose down
```
If you want to remove the created files on the host:
- Stop and remove containers as above.
- Remove `/projects/jenkins-installation` (or the `ROOT_DIR` you selected) and any artifacts that were created. Example:
```datalex/jenkins-installation/README.md#L1-3
sudo rm -rf /projects/jenkins-installation
```
Use caution — this will delete Jenkins data and secrets.

Troubleshooting
===============
Docker not running / permission denied
- Confirm docker is installed and the daemon is running:
```datalex/jenkins-installation/README.md#L1-3
sudo systemctl status docker
sudo systemctl enable --now docker
```
- If you get permission errors with the `docker` CLI, ensure you ran `docker` commands as a user with permission or using `sudo`.

Docker Compose issues
- If `docker-compose` is missing, the script tries to install `/usr/local/bin/docker-compose`. If your environment expects the plugin `docker compose`, use that instead.
- Check `docker-compose` version:
```datalex/jenkins-installation/README.md#L1-2
docker-compose --version
# or
docker compose version
```

Jenkins fails to start
- View container logs:
```datalex/jenkins-installation/README.md#L1-3
docker logs -f jenkins
```
- Common causes:
  - Incorrect file permissions on mounted volumes (Jenkins cannot write to `JENKINS_HOME`).
  - Missing or invalid plugin versions in `plugins.txt`.
  - SELinux blocking container volume mounts (consider setting SELinux to permissive if troubleshooting, or use proper SELinux labels).

Port conflicts
- If port 8080 is already in use on the host, update `docker-compose/docker-compose.yml` ports mapping before starting, or stop the service occupying that port.

SELinux
- On systems with SELinux enabled, container mounts may require appropriate SELinux contexts. If you see permission denied errors, either:
  - Use `:z` or `:Z` mount options where appropriate, or
  - Temporarily set SELinux to permissive for troubleshooting:
```datalex/jenkins-installation/README.md#L1-2
sudo setenforce 0
sudo setenforce 1  # return to enforcing mode after testing
```

Security notes
==============
- The script writes the Jenkins admin password to `jenkins/jenkins_home/secrets/adminPassword` — protect this file and the `jenkins` host directory.
- The SSH private key you provide will be placed into `jenkins-ssh/id_rsa` on the host and mounted into the container (read-only). Ensure the key is appropriate for use inside Jenkins.
- If you enable AWS CLI, avoid placing long-term AWS credentials in unprotected files. Prefer IAM roles or minimal-scoped credentials.
- The script disables the Jenkins setup wizard by setting `JAVA_OPTS=-Djenkins.install.runSetupWizard=false`. The admin user is pre-created using the admin password supplied. Keep that password safe and rotate as needed.

Advanced tips
=============
- Rebuild the Jenkins image after editing `plugins.txt` or the Dockerfile:
```datalex/jenkins-installation/README.md#L1-3
cd /projects/jenkins-installation/docker-compose
docker-compose build --no-cache
docker-compose up -d
```
- To add more host-level configuration (custom CA certs, credentials, secret stores), modify `jenkins` Dockerfile / entrypoint and JCasC `jenkins/casc/jenkins.yaml`.

Contributing / Contact
======================
- If you find issues with the installer script or have suggestions (e.g., support for `apt`-based hosts, systemd-managed Jenkins, or Kubernetes manifests), open an issue or submit a pull request in this repository.
- When submitting issues provide:
  - Host OS and version
  - Docker version
  - Full output of `sudo ./install_jenkins.sh` (or relevant logs)
  - The sections of `docker-compose/docker-compose.yml` and `jenkins/casc/jenkins.yaml` you changed (if any)

Appendix — Example quick-run (non-interactive adaptation)
=========================================================
If you wish to run the script non-interactively, you can pre-populate or modify the script variables at the top (`ROOT_DIR`, `JENKINS_UID`, `JENKINS_GID`) and comment out or modify the `read` prompts so they source values from environment variables. Be cautious when automating secret entry — store secrets in a secure secret store or pass via secure pipelines.

License
=======
This repository contains example automation for setting up Jenkins and is provided "as-is". Review plugins and configurations before deploying.

---

End of README.
