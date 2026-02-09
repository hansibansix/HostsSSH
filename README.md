# Hosts SSH

A DankBar widget plugin for DankMaterialShell that provides quick SSH access to hosts defined in `/etc/hosts`.

## Features

- Parses `/etc/hosts` for entries with a configurable prefix (or all hosts if prefix is empty)
- Displays host count in the bar
- Click to open a searchable popout with all matching hosts
- Fuzzy search by hostname or IP address
- Keyboard navigation (↑/↓/Tab to navigate, Enter to connect, Escape to close)
- Click any host to open an SSH connection in your terminal
- Kitty users: opens in a new tab if kitty is already running
- Auto-refreshes host list every 30 seconds

## Installation

```bash
# Clone or copy to your plugins directory
cp -r HostsSSH ~/.config/DankMaterialShell/plugins/

# Restart DMS or scan for plugins
dms restart
```

Then:
1. Open DMS Settings → Plugins
2. Click "Scan for Plugins"
3. Toggle "Hosts SSH" on
4. Add to your DankBar widget list

## Keybind Setup

To toggle the widget with a keyboard shortcut, add to your compositor config:

**Hyprland** (`~/.config/hypr/hyprland.conf`):
```
bind = SUPER, S, exec, dms ipc call widget toggle hostsSSH
```

**Sway** (`~/.config/sway/config`):
```
bindsym $mod+s exec dms ipc call widget toggle hostsSSH
```

**Niri** (`~/.config/niri/config.kdl`):
```kdl
binds {
    Mod+S { spawn "dms" "ipc" "call" "widget" "toggle" "hostsSSH"; }
}
```

## Configuration

In Settings → Plugins → Hosts SSH:

| Setting | Description | Default |
|---------|-------------|---------|
| Terminal Emulator | Which terminal to use for SSH | foot |
| Kitty Socket | Socket path for kitty remote control | `unix:@mykitty` |
| Default SSH User | Username for SSH (empty = system default) | (empty) |
| Host Prefix | Only show hosts starting with this (empty = all hosts) | `m-` |
| Hosts File Path | Path to hosts file | `/etc/hosts` |
| Clone Directory | Directory to clone repos into (empty = home) | (empty) |

## Kitty Tab Support

If you use kitty and want SSH connections to open in tabs instead of new windows:

1. Add to your `~/.config/kitty/kitty.conf`:
   ```
   allow_remote_control yes
   listen_on unix:@mykitty
   ```

2. Set the "Kitty Socket" setting to match your `listen_on` value (default: `unix:@mykitty`)

The plugin will automatically detect running kitty instances and open new connections as tabs.

## Example /etc/hosts

```
192.168.1.10    m-webserver m-web
192.168.1.20    m-database m-db
10.0.0.5        dev-server
10.0.0.10       prod-api
172.16.0.100    nas storage
```

## Keyboard Navigation

| Key | Action |
|-----|--------|
| ↑/↓ | Navigate through hosts |
| Tab | Cycle through hosts |
| Enter | Connect to selected host |
| Escape | Clear search / Close popout |
| Shift+Escape | Clear search, show full list |
| Super+Enter | Expand/collapse git repos for selected host |

## Git Repository Browser

The plugin can fetch and display git repositories from hosts running Gitea, Gogs, GitLab, or similar git servers.

**To browse repos:**
- Right-click on any host, OR
- Press Super+Enter with a host selected, OR  
- Click the expand icon on the right side of a host entry

**Once expanded:**
- Click a repo row to clone it to your configured Clone Directory
- Click the **download icon** (↓) to clone the repo
- Click the **copy icon** to copy the clone URL to clipboard

**Requirements:**
- SSH key authentication set up for `git@hostname`
- The git server must list repos when you SSH as the git user

## License

MIT
