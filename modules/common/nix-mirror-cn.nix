# Chinese Nix substituter mirrors — opt-in module
#
# Import this module in hosts located in mainland China for faster downloads.
# Do NOT import for overseas machines where official cache is faster.
{ ... }:

{
  nix.settings.substituters = [
    "https://mirror.sjtu.edu.cn/nix-channels/store"
    "https://mirrors.ustc.edu.cn/nix-channels/store"
  ];
}
