#!/bin/zsh
# Print the title of the first item in the Mixer's local Edit menu (the Undo item), then close the menu.
D=$(dirname $0)
osascript -e 'tell application "Logic Pro" to activate' >/dev/null
$D/menubtn Edit >/dev/null; sleep 0.5
~/dev/logic-pro-mcp/tools/ax-dump/ax-dump --depth 14 2>/dev/null | grep -m1 -o 'AXMenuItem title="\(Undo\|Can.t Undo\)[^"]*"'
osascript -e 'tell application "System Events" to key code 53'
