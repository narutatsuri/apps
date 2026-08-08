#!/bin/bash
# Builds and installs the apps. With no arguments, all of them.
#
# Each app's build.sh does the real work and also launches what it built, which
# is why this stops at the first failure rather than carrying on: a half-built
# set of menu-bar apps is worse than none, because the ones that did install
# look like everything worked.
set -euo pipefail
cd "$(dirname "$0")"

apps=("$@")
if [ ${#apps[@]} -eq 0 ]; then
  apps=(CodingAgentUsage Jot PaperNotes Pomodoro VoiceBridge)
fi

for app in "${apps[@]}"; do
  if [ ! -x "$app/build.sh" ]; then
    echo "no such app: $app" >&2
    exit 1
  fi
  echo "==> $app"
  ( cd "$app" && ./build.sh )
done

echo
echo "Done. Menu-bar apps show no Dock icon — look in the menu bar."
echo "VoiceBridge needs Accessibility permission; Jot's hotkeys do not."
