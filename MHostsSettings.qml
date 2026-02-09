import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "hostsSSH"

    StyledText {
        width: parent.width
        text: "Hosts SSH"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Quick SSH launcher for hosts from /etc/hosts"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // Keybind section
    StyledText {
        width: parent.width
        text: "Keybind"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    StyledText {
        width: parent.width
        text: "Add this to your compositor config to toggle the widget:"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: keybindCommand.height + Theme.spacingM
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Row {
            anchors.fill: parent
            anchors.margins: Theme.spacingS
            spacing: Theme.spacingS

            StyledText {
                id: keybindCommand
                text: "dms ipc call widget toggle hostsSSH"
                font.pixelSize: Theme.fontSizeSmall
                font.family: "monospace"
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            Item { 
                width: parent.width - keybindCommand.width - copyIcon.width - Theme.spacingS * 2
                height: 1
            }

            DankIcon {
                id: copyIcon
                name: "content_copy"
                size: Theme.iconSizeSmall
                color: copyMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                    id: copyMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Quickshell.execDetached(["sh", "-c", "echo -n 'dms ipc call widget toggle hostsSSH' | wl-copy"]);
                        ToastService.showInfo("Copied", "Command copied to clipboard");
                    }
                }
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Example for Hyprland: bind = SUPER, S, exec, dms ipc call widget toggle hostsSSH"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        topPadding: Theme.spacingXS
    }

    // Terminal section
    StyledText {
        width: parent.width
        text: "Terminal"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    SelectionSetting {
        settingKey: "terminal"
        label: "Terminal Emulator"
        description: "Terminal to use for SSH connections"
        options: [
            { label: "Foot", value: "foot" },
            { label: "Alacritty", value: "alacritty" },
            { label: "Kitty", value: "kitty" },
            { label: "WezTerm", value: "wezterm" },
            { label: "GNOME Terminal", value: "gnome-terminal" },
            { label: "Konsole", value: "konsole" }
        ]
        defaultValue: "foot"
    }

    StringSetting {
        settingKey: "kittySocket"
        label: "Kitty Socket"
        description: "Socket path for kitty remote control (from listen_on in kitty.conf)"
        placeholder: "unix:@mykitty"
        defaultValue: "unix:@mykitty"
    }

    StringSetting {
        settingKey: "sshUser"
        label: "Default SSH User"
        description: "Leave empty to use system default"
        placeholder: "username"
        defaultValue: ""
    }

    // Hosts section
    StyledText {
        width: parent.width
        text: "Hosts"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    StringSetting {
        settingKey: "hostPrefix"
        label: "Host Prefix"
        description: "Only show hosts starting with this prefix (leave empty for all hosts)"
        placeholder: "m-"
        defaultValue: "m-"
    }

    StringSetting {
        settingKey: "hostsFile"
        label: "Hosts File Path"
        description: "Path to the hosts file"
        placeholder: "/etc/hosts"
        defaultValue: "/etc/hosts"
    }

    // Git section
    StyledText {
        width: parent.width
        text: "Git"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    StringSetting {
        settingKey: "cloneDirectory"
        label: "Clone Directory"
        description: "Directory to clone repositories into (empty = home directory)"
        placeholder: "~/projects"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "repoSearchPrefix"
        label: "Repo Search Prefix"
        description: "Prefix to search repositories instead of hosts (e.g. '!myrepo')"
        placeholder: "!"
        defaultValue: "!"
    }
}
