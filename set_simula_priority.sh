# Set Simula and its children (Godot)
sudo renice -n -20 -u $(whoami) -p $(pgrep simula)
# Set the SteamVR heavy lifters
sudo renice -n -20 -p $(pgrep vrserver)
sudo renice -n -20 -p $(pgrep vrcompositor)
