

# overwrite greeting
# potentially disabling fastfetch
#function fish_greeting
#    # smth smth
#end
if status is-interactive
set -U fish_greeting
echo -n "> "
end

# cargo
fish_add_path -m $HOME/.cargo/bin

# Qt theme via qt6ct (matugen)
set -x QT_QPA_PLATFORMTHEME qt6ct
set -x QT_QPA_PLATFORM wayland
