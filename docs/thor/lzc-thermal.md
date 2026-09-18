# Lazycat AI Pod thermal control on Thor

[Thor system notes](system.md)

Read-only inspection on 2026-09-18 traced the fan selector in AI Pod 2.2.4
through the management backend and compute-capsule agent to the fan daemon on
one Jetson AGX Thor T5000. Evidence came from the installed frontend bundle,
symbols and diagnostic strings in the installed Go binaries, backend access
logs, the live device information endpoint, the daemon's Unix-socket API and
the resulting sysfs PWM value. No authentication material or device identifier
is retained here.

This describes observed behavior, not a stable public API. The agent and
backend are versioned private implementation details and may change without
compatibility guarantees.

## Control path

The device-information component renders the fan selector only when the device
record contains `lzcThermalProfile`. Its two values are:

| UI label | Wire value |
| --- | --- |
| Quiet (`安静模式`) | `<Max-Q>` |
| Performance (`性能模式`) | `<Max-P>` |

Changing the selection calls:

```text
GET /backend/device/lzcthermal/setProfile
    ?serialNumber=<device>&profile=<Max-Q|Max-P>
```

The application Caddy instance strips `/backend` and sends the request to the
AI Pod backend on port 8070. The backend handler is
`DeviceManager.setLzcThermalProfile`. A captured successful request selected
`<Max-P>` and completed in 19.5 ms.

The backend then relays the request to the authenticated device agent. The
agent advertises `_ai_jetson._tcp` and serves its versioned device API on port
40793. Its thermal endpoint is `/v1/lzcthermal/setProfile`; direct mutation
without the device token returned HTTP 403. The installed agent contains
`SetThermalProfile`, `GetThermalProfile` and `formatThermalProfile` handlers in
`backend/client/thermal.go`.

The agent talks to `lzc-thermald` through
`/run/lzc-thermal/daemon.sock`. `GET /config` is a useful read-only diagnostic;
the selected controller state is also stored in
`/run/lzc-thermal/config.json`. The file is runtime state, not a persistent
declaration.

`lzc-thermald` owns the `pwmfan` hwmon controller and writes its PWM output.
The agent disables NVIDIA's `nvfancontrol.service` while installing the Lazycat
daemon. Diagnostic strings show an explicit fallback which restores
`nvfancontrol` when configuring or starting the Lazycat daemon fails.

## Observed profiles

The controller was in automatic mode, sampled the `gpu-thermal` and
`cpu-thermal` zones every 100 ms and used the hotter value. The daemon returned
these profiles:

| Profile | Temperature | PWM |
| --- | ---: | ---: |
| `<Max-P>` | 30 C | 80 |
| | 70 C | 180 |
| | 80 C | 225 |
| | 100 C | 255 |
| `<Max-Q>` | 20 C | 0 |
| | 49 C | 0 |
| | 50 C | 30 |
| | 60 C | 80 |
| | 70 C | 128 |
| | 75 C | 180 |
| | 80 C | 200 |
| | 100 C | 255 |
| `<full>` | 0 C | 255 |

The daemon linearly interpolates between points. The returned `hystereis`
values were 1,000 for Performance, 5,000 for Quiet and 100 for Full. At about
52 C, the observed PWM of 40 matched the Quiet interpolation between 50 C/30
and 60 C/80.

## Persisted selection versus active state

The AI Pod backend retained `<Max-P>` and its access log showed the earlier
successful Performance selection. After the machine rebooted into the adapted
NixOS environment, however, `lzc-thermald` created a fresh runtime file with
`<Max-Q>`. Both the Unix-socket configuration and the agent's read-only
`/v1/info` endpoint reported Quiet.

The adapted NixOS agent was not a complete replacement for the factory control
plane. Its service-forward component repeatedly failed to reach the local
Traefik endpoint, the management application kept a stale factory-system device
record and marked it offline, and later model-host operations encountered
protocol mismatches. Consequently the backend's saved Performance selection was
not restored on NixOS.

This distinction changes the environment labels for the model experiments:

- official AI Pod and factory-system measurements used Performance; and
- self-hosted NixOS SGLang tuning through the 71-minute bounded stability run
  used Quiet.

The NixOS run completed 34 correct rounds before it was deliberately stopped.
It reached 70.2 C but held the active GPU clock at 1,385--1,386 MHz, so no
thermal downclock was observed.

## NixOS ownership boundary

The NixOS configuration no longer attempts to run the private Lazycat agent,
Traefik bridge or `lzc-thermald`. The factory system remains the reference for
measuring the complete official AI Pod stack.

On NixOS, fan control is fleet-owned and declarative. A small host-specific
controller reproduces the observed `<Max-P>` points, reads the maximum of the
CPU and GPU thermal zones once per second and writes `pwmfan/pwm1`. Failure to
read both sensors selects PWM 255. The service conflicts with
`lzc-ai-agent.service`, `lzc-thermald.service` and `nvfancontrol.service`, so
only one process can own the PWM controller. This deliberately avoids depending
on the private device token or on compatibility with the AI Pod model-host
protocol.
