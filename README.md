<div align="center">

# 🚀 Asterisk 22 Safe Installer for Rocky Linux 10

![Asterisk](https://img.shields.io/badge/Asterisk-22-brightgreen)
![Rocky Linux](https://img.shields.io/badge/Rocky%20Linux-9%20%7C%2010-blue)
![WebRTC](https://img.shields.io/badge/WebRTC-Enabled-purple)
![OPUS](https://img.shields.io/badge/Codec-OPUS-orange)
![SRTP](https://img.shields.io/badge/Security-SRTP-red)
![License](https://img.shields.io/badge/License-MIT-lightgrey)
[![Bash](https://img.shields.io/badge/Bash-5.0+-4EAA25)](https://www.gnu.org/software/bash/)

**A comprehensive, production-ready Asterisk PBX installation script with modern codec support**
</div>

## ✨ Features

### 📦 **Core Components**
- ✅ **Asterisk 22** LTS with PJSIP stack
- ✅ **MariaDB/MySQL** integration with ODBC
- ✅ **Systemd** service configuration
- ✅ **Automatic firewall** rules (firewalld)
- ✅ **SELinux** compatibility mode

### 🔊 **Codec Support**
- ✅ **WebRTC** ready (OPUS, VP8)
- ✅ **OPUS** codec (high quality, low bandwidth)
- ✅ **G.729** via asterisk-g72x (open-source implementation)
- ✅ **G.711** (ulaw/alaw)
- ✅ **MP3** playback support via FFmpeg
- ✅ **SRTP** for secure media

### 🔧 **Smart Features**
- 🔄 **Intelligent rebuild detection** - reuses existing installations
- 🛡️ **Safe database configuration** - proper MariaDB authentication
- 📊 **Interactive prompts** - user-friendly configuration
- 🎨 **Color-coded output** - easy to read progress
- 📝 **Error logging** - detailed troubleshooting
- 🔒 **Security-first** - minimal exposure, secure defaults

## 🚀 Quick Start

### Prerequisites
- **Rocky Linux 10** (fresh installation recommended)
- **Root or sudo privileges**
- **Minimum 2GB RAM, 20GB disk space**
- **Active internet connection**

### Installation

```bash
# Download the script
curl -O https://raw.githubusercontent.com/yourusername/asterisk-installer/main/install-asterisk.sh

# Make it executable
chmod +x install-asterisk.sh

# Run as root
sudo ./install-asterisk.sh
