{ pkgs, ... }:

let
  fanControl = pkgs.writeShellScript "thor-fan-control" ''
    set -u

    pwm_path=
    enable_path=
    for candidate in /sys/class/hwmon/hwmon*; do
      if [[ -r "$candidate/name" ]] && [[ "$(< "$candidate/name")" == pwmfan ]]; then
        pwm_path="$candidate/pwm1"
        enable_path="$candidate/pwm1_enable"
        break
      fi
    done

    if [[ -z "$pwm_path" || ! -w "$pwm_path" || ! -w "$enable_path" ]]; then
      echo "writable pwmfan controller not found" >&2
      exit 1
    fi

    thermal_zones=()
    for candidate in /sys/class/thermal/thermal_zone*; do
      [[ -r "$candidate/type" ]] || continue
      case "$(< "$candidate/type")" in
        cpu-thermal|gpu-thermal)
          thermal_zones+=("$candidate/temp")
          ;;
      esac
    done

    printf '1\n' > "$enable_path"
    last_pwm=-1

    while true; do
      max_temp=-1
      for sensor in "''${thermal_zones[@]}"; do
        value=
        if IFS= read -r value < "$sensor" 2>/dev/null && [[ "$value" =~ ^[0-9]+$ ]] && (( value > max_temp )); then
          max_temp=$value
        fi
      done

      if (( max_temp < 0 )); then
        temp_c=-1
        target_pwm=255
      else
        temp_c=$(( (max_temp + 500) / 1000 ))
        if (( temp_c <= 30 )); then
          target_pwm=80
        elif (( temp_c <= 70 )); then
          target_pwm=$(( 80 + (temp_c - 30) * 100 / 40 ))
        elif (( temp_c <= 80 )); then
          target_pwm=$(( 180 + (temp_c - 70) * 45 / 10 ))
        elif (( temp_c <= 100 )); then
          target_pwm=$(( 225 + (temp_c - 80) * 30 / 20 ))
        else
          target_pwm=255
        fi
      fi

      if (( target_pwm != last_pwm )); then
        printf '%s\n' "$target_pwm" > "$pwm_path"
        printf 'temperature=%sC pwm=%s\n' "$temp_c" "$target_pwm"
        last_pwm=$target_pwm
      fi
      sleep 1
    done
  '';

  fanStop = pkgs.writeShellScript "thor-fan-stop" ''
    for candidate in /sys/class/hwmon/hwmon*; do
      if [[ -r "$candidate/name" ]] && [[ "$(< "$candidate/name")" == pwmfan ]]; then
        printf '1\n' > "$candidate/pwm1_enable"
        printf '255\n' > "$candidate/pwm1"
        break
      fi
    done
  '';
in
{
  services.nvfancontrol.enable = false;

  systemd.services.thor-fan-control = {
    description = "Thor performance fan control";
    wantedBy = [ "multi-user.target" ];
    before = [ "thor-inference.service" ];
    conflicts = [
      "lzc-ai-agent.service"
      "lzc-thermald.service"
      "nvfancontrol.service"
    ];
    unitConfig = {
      StartLimitIntervalSec = 30;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = fanControl;
      ExecStopPost = fanStop;
      Restart = "always";
      RestartSec = 2;
    };
  };

  systemd.services.thor-inference = {
    wants = [ "thor-fan-control.service" ];
    after = [ "thor-fan-control.service" ];
  };
}
