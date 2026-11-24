#!/bin/bash
# Removes the two Claude Sessions Pro profiles (Work and Personal) by moving them to the Trash.
# Leaves alone: the Claude Sessions Pro app, /Applications/Claude Personal.app (your own
# AppleScript launcher), the regular Claude app and its account, and Harbor.
#
# Usage:  bash ~/Documents/Harbor/remove-sessions-pro-profiles.sh
set -u

SP="$HOME/Library/Application Support/Claude Sessions Pro"
PROFILE_IDS=(A40CB882-E891-480A-9509-5DAFDF268173 FD8BE98F-93E9-4D1A-A7BF-F1A207215761)
PROFILE_APPS=("$HOME/Applications/Claude Profiles/Claude Work.app"
              "$HOME/Applications/Claude Profiles/Claude Personal.app")

echo "This moves the Sessions Pro profiles \"Work\" and \"Personal\" to the Trash:"
for id in "${PROFILE_IDS[@]}"; do echo "  $SP/Profiles/$id"; done
for app in "${PROFILE_APPS[@]}"; do echo "  $app"; done
echo "It first quits Claude Sessions Pro and both profile windows (you'll be signed out of them)."
read -r -p "Continue? [y/N] " answer
[[ "$answer" == [yY]* ]] || { echo "Cancelled. Nothing was changed."; exit 0; }

# 1. Quit Sessions Pro so it doesn't reopen the profiles.
osascript -e 'tell application id "com.lexmedia.ClaudeSessionsPro" to quit' 2>/dev/null

# 2. Quit the processes that belong to these two profiles only.
pids_for_profiles() {
  for id in "${PROFILE_IDS[@]}"; do pgrep -f -- "Claude Sessions Pro/Profiles/$id/Data"; done
  for app in "${PROFILE_APPS[@]}"; do pgrep -f -- "$app/"; done
}
PIDS=$(pids_for_profiles | sort -u)
[ -n "$PIDS" ] && kill -TERM $PIDS 2>/dev/null
for _ in $(seq 1 20); do
  [ -z "$(pids_for_profiles)" ] && break
  sleep 1
done
LEFT=$(pids_for_profiles | sort -u)
if [ -n "$LEFT" ]; then
  echo "Some profile processes didn't quit; forcing them: $LEFT"
  kill -KILL $LEFT 2>/dev/null
  sleep 2
fi

# 3. Move the profile data and profile apps to the Trash.
for id in "${PROFILE_IDS[@]}"; do
  [ -e "$SP/Profiles/$id" ] && trash -v "$SP/Profiles/$id"
done
for app in "${PROFILE_APPS[@]}"; do
  [ -e "$app" ] && trash -v "$app"
done
# Remove the now-empty "Claude Profiles" folder if nothing else is in it.
rmdir "$HOME/Applications/Claude Profiles" 2>/dev/null

# 4. Empty Sessions Pro's profile list (a copy of the old list goes to the Trash).
if [ -f "$SP/profiles.json" ]; then
  BACKUP="$(mktemp -d)/profiles (Sessions Pro backup).json"
  cp "$SP/profiles.json" "$BACKUP" && trash "$BACKUP"
  plutil -replace profiles -json '[]' "$SP/profiles.json"
fi

echo
echo "Done. Both profiles are in the Trash; empty it when you're sure you don't need them."
echo "Next: open Harbor from Applications and create your profiles."
