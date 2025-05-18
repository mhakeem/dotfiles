sudo apt update -y && sudo apt upgrade -y
sudo apt install -y curl gpg wget git unzip ubuntu-restricted-extras
sudo apt install -y \
  # first line is for Ruby
  autoconf patch build-essential rustc libssl-dev libyaml-dev libreadline6-dev zlib1g-dev libgmp-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev libdb-dev uuid-dev \
  pkg-config bison clang libreadline-dev libreadline-dev libjemalloc2 \
  libvips imagemagick libmagickwand-dev mupdf mupdf-tools gir1.2-gtop-2.0 gir1.2-clutter-1.0 \
  redis-tools sqlite3 libsqlite3-0 libmysqlclient-dev libpq-dev postgresql-client postgresql-client-common

# Zsh
sudo apt install zsh fonts-font-awesome
chsh -s $(which zsh)
# NOTE: must logout

# Fonts
### START ###

install_font() {
	local font_name=$1
	local url=$2
	local file_type=$3
	local file_name="${font_name/ Nerd Font/}"

	if ! $(fc-list | grep -i "$font_name" >/dev/null); then
		cd /tmp
		wget -O "$file_name.zip" "$url"
		unzip "$file_name.zip" -d "$file_name"
		cp "$file_name"/*."$file_type" ~/.local/share/fonts
		rm -rf "$file_name.zip" "$file_name"
		fc-cache
		cd -
		clear
	fi
}

mkdir -p ~/.local/share/fonts

install_font "FiraMono Nerd Font" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraMono.zip" "otf"

install_font "JetBrainsMono Nerd Font" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" "ttf"

install_font "MesloLGS Nerd Font" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip" "ttf"

install_font "CaskaydiaMono Nerd Font" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaMono.zip" "ttf"

cd /tmp
wget -O iafonts.zip https://github.com/iaolo/iA-Fonts/archive/refs/heads/master.zip
unzip iafonts.zip -d iaFonts
cp iaFonts/iA-Fonts-master/iA\ Writer\ Mono/Static/iAWriterMonoS-*.ttf ~/.local/share/fonts
rm -rf iafonts.zip iaFonts

cd ~/.local/share/fonts
wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf
wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf
wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf
wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf

fc-cache
cd -

# install Github Monaspace fonts
cd /tmp/
git clone git@github.com:githubnext/monaspace.git
mkdir ~/.local/share/fonts/Monaspace
cp monaspace/fonts/otf/* ~/.local/share/fonts/Monaspace/
cp monaspace/fonts/frozen/* ~/.local/share/fonts/Monaspace/
cp monaspace/fonts/variable/* ~/.local/share/fonts/Monaspace/
rm -rf monaspace
fc-cache -f
cd -

### END ###

# # Luminance (brightness contorller) NOTE: Doesn't work on Ubuntu
# cd /tmp/
# wget http://archive.ubuntu.com/ubuntu/pool/universe/d/ddcutil/libddcutil4_1.4.1-1build2_amd64.deb
# wget https://github.com/sidevesh/Luminance/releases/download/1.1.0/luminance-1.1.0.deb
# sudo apt install ./libddcutil4_1.4.1-1build2_amd64.deb
# sudo apt install ./luminance-1.1.0.deb
# rm libddcutil4_1.4.1-1build2_amd64.deb
# luminance-1.1.0.deb
# cd -

# Zsh4humans
if command -v curl >/dev/null 2>&1; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/romkatv/zsh4humans/v5/install)"
else
  sh -c "$(wget -O- https://raw.githubusercontent.com/romkatv/zsh4humans/v5/install)"
fi
# NTOE: Run `p10k configure`

# fastfecth: Display system information in the terminal
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update -y
sudo apt install -y fastfetch

# Gnome tweak
sudo apt install -y gnome-tweaks
sudo apt install -y gnome-tweak-tool

# Gnome extension manager
sudo apt install gnome-shell-extension-manager -y

# Flatpak (APT alternative)
sudo apt install -y flatpak
sudo apt install -y gnome-software-plugin-flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# # Nala (APT alternative)
# sudo apt install -y nala
# sudo nala fetch
# # To show Debian packages in Ubuntu Software Center or App Center
# sudo nala install gdebi

# To run AppImage (Linux executable that runs on any distro)
sudo add-apt-repository -y universe
sudo apt update
sudo apt install -y libfuse2t64

# Terminal utility apps
sudo apt install -y fzf ripgrep bat eza zoxide plocate btop fd-find tldr bat tmux

# Zellij
sudo snap install zellij --classic

# Neovim
sudo snap install nvim --classic
# Install luarocks and tree-sitter-cli to resolve lazyvim :checkhealth warnings
sudo apt install -y luarocks tree-sitter-cli

# Lazyvim (must install Neovim first)
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git

# Obsidian
flatpak install -y flathub md.obsidian.Obsidian

# VS Code
cd /tmp
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >packages.microsoft.gpg
sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
rm -f packages.microsoft.gpg
cd -
sudo apt update -y
sudo apt install -y code

# VSCodium
wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
    | gpg --dearmor \
    | sudo dd of=/usr/share/keyrings/vscodium-archive-keyring.gpg
echo 'deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main' \
    | sudo tee /etc/apt/sources.list.d/vscodium.list
sudo apt update && sudo apt install -y codium

# LazyGit
cd /tmp
LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
curl -sLo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
tar -xf lazygit.tar.gz lazygit
sudo install lazygit /usr/local/bin
rm lazygit.tar.gz lazygit
mkdir -p ~/.config/lazygit/
touch ~/.config/lazygit/config.yml
cd -

# Wayland clipboard
sudo apt install -y wl-clipboard

# ULauncher
# NOTE: Doesn't work on 25.04. Download .deb from site directly
# sudo add-apt-repository universe -y && sudo add-apt-repository ppa:agornostal/ulauncher -y && sudo apt update -y && sudo apt install -y ulauncher


# Brave
# ### START ###
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main"|sudo tee /etc/apt/sources.list.d/brave-browser-release.list
sudo apt update -y
sudo apt install brave-browser -y
# ### END ###

# Chrome
cd /tmp
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install -y ./google-chrome-stable_current_amd64.deb
rm google-chrome-stable_current_amd64.deb
cd -

# MS Edge
sudo apt install software-properties-common apt-transport-https curl ca-certificates -y
curl -fSsL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor | sudo tee /usr/share/keyrings/microsoft-edge.gpg > /dev/null
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main' | sudo tee /etc/apt/sources.list.d/microsoft-edge.list
sudo apt update -y
sudo apt install -y microsoft-edge-stable

# Firefox developer edition. See https://linux.how2shout.com/how-to-install-firefox-developer-edition-on-ubuntu-22-04-or-20-04/
cd /tmp
wget "https://download.mozilla.org/?product=firefox-devedition-latest-ssl&os=linux64&lang=en-US" -O firefox-dev.tar.xz
sudo tar -xf firefox-dev.tar.xz -C /opt/
rm firefox-dev.tar.xz
sudo ln -s /opt/firefox/firefox /usr/local/bin/firefox-dev
cd -
cat > ~/.local/share/applications/firefox-dev.desktop << "EOF"
[Desktop Entry]
Name=Firefox Developer Edition
Exec=/usr/local/bin/firefox-dev
Icon=/opt/firefox/browser/chrome/icons/default/default128.png
comment=browser
Type=Application
Terminal=false
Encoding=UTF-8
Categories=Utility;
EOF

# Docker
# ### START ###
# Add the official Docker repo
sudo install -m 0755 -d /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update

# Install Docker engine and standard plugins
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

# Give this user privileged Docker access
sudo usermod -aG docker ${USER}

# Limit log size to avoid running out of disk
echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"5"}}' | sudo tee /etc/docker/daemon.json
# ### END ###

# LazyDocker
cd /tmp
LAZYDOCKER_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazydocker/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
curl -sLo lazydocker.tar.gz "https://github.com/jesseduffield/lazydocker/releases/latest/download/lazydocker_${LAZYDOCKER_VERSION}_Linux_x86_64.tar.gz"
tar -xf lazydocker.tar.gz lazydocker
sudo install -y lazydocker /usr/local/bin
rm lazydocker.tar.gz lazydocker
cd -

# LocalSend (Nearby devices file share)
cd /tmp
LOCALSEND_VERSION=$(curl -s "https://api.github.com/repos/localsend/localsend/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
wget -O localsend.deb "https://github.com/localsend/localsend/releases/latest/download/LocalSend-${LOCALSEND_VERSION}-linux-x86-64.deb"
sudo apt install -y ./localsend.deb
rm localsend.deb
cd -

# Gives you previews in the file manager when pressing space
sudo apt install -y gnome-sushi

# 1Password
cd /tmp
wget -O 1password.deb https://downloads.1password.com/linux/debian/amd64/stable/1password-latest.deb
sudo apt install -y ./1password.deb
rm 1password.deb
cd -

# Alacritty
sudo apt install -y alacritty
mkdir -p ~/.config/alacritty/themes
git clone https://github.com/alacritty/alacritty-theme ~/.config/alacritty/themes


# Mise
sudo install -dm 755 /etc/apt/keyrings
wget -qO - https://mise.jdx.dev/gpg-key.pub | gpg --dearmor | sudo tee /etc/apt/keyrings/mise-archive-keyring.gpg 1>/dev/null
echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=$(dpkg --print-architecture)] https://mise.jdx.dev/deb stable main" | sudo tee /etc/apt/sources.list.d/mise.list
sudo apt update
sudo apt install -y mise
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
exec zsh

# Install languages after installing mise
mise use --global python@latest
mise use --global node@lts
mise use --global ruby@latest

# Spotify
sudo snap install spotify

# Slack
sudo snap install slack

# PIA
cd /tmp
wget -O pia-installer.run https://installers.privateinternetaccess.com/download/pia-linux-3.6.1-08339.run
sh pia-installer.run
rm pia-installer.run
cd -

# Zoom
flatpak install flathub us.zoom.Zoom -y

# Resources (like system monitor)
flatpak install flathub net.nokyan.Resources -y

# Grub customizer
sudo add-apt-repository -y ppa:danielrichter2007/grub-customizer
sudo apt update
sudo apt install -y grub-customizer

### AI Apps ###
# LM Studio
cd /tmp
wget https://installers.lmstudio.ai/linux/x64/0.3.15-11/LM-Studio-0.3.15-11-x64.AppImage
chmod +x ./LM-Studio-0.3.15-11-x64.AppImage
sudo mkdir /opt/LMStudio
sudo install ./LM-Studio-0.3.15-11-x64.AppImage /opt/LMStudio/LM-Studio.AppImage
rm LM-Studio-0.3.15-11-x64.AppImage
cd -
# Download icon
sudo wget "https://lmstudio.ai/_next/image?url=%2F_next%2Fstatic%2Fmedia%2Flmstudio-app-logo.61cb7d80.webp&w=3840&q=75" -O /usr/share/icons/lmstudio.png
# Create desktop entry
cat > ~/.local/share/applications/lmstudio.desktop << "EOF"
[Desktop Entry]
Name=LM Studio
Comment=LM Studio Launcher
Exec=/opt/LMStudio/LM-Studio.AppImage --no-sandbox
Icon=/usr/share/icons/lmstudio.png
Terminal=false
Type=Application
Categories=Development;
EOF
# if you have models, copy them to ~/.lmstudio/models

# GPT4All
cd /tmp
wget https://gpt4all.io/installers/gpt4all-installer-linux.run
chmod +x ./gpt4all-installer-linux.run
./gpt4all-installer-linux.run
# that will start installer gui
rm gpt4all-installer-linux.run
cd -

# Jan.ai
cd /tmp
wget -O jan-linux.deb https://github.com/menloresearch/jan/releases/download/v0.5.16/jan-linux-amd64-0.5.16.deb
sudo apt install ./jan-linux.deb
rm jan-linux.deb
cd -

# Chatbox
cd /tmp
wget -O ChatboxAi.AppImage https://chatboxai.app/install_chatbox/linux
chmod +x ./ChatboxAi.AppImage
sudo mkdir /opt/ChatboxAi
sudo install ./ChatboxAi.AppImage /opt/ChatboxAi/ChatboxAi.AppImage
rm ChatboxAi.AppImage
cd -
# download icon
sudo wget https://chatboxai.app/icon.png -O /usr/share/icons/chatboxai.png
# Create desktop entry
cat > ~/.local/share/applications/chatboxai.desktop << "EOF"
[Desktop Entry]
Name=Chatbox AI
Comment=Chatbox AI Launcher
Exec=/opt/ChatboxAi/ChatboxAi.AppImage --no-sandbox
Icon=/usr/share/icons/chatboxai.png
Terminal=false
Type=Application
Categories=Development;
EOF


# ### Gnome Settings ###
# minimize by clicking on the dock
gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize'