{
  fetchurl,
  gzip,
  python3,
  stdenvNoCC,
  source,
  chinaIpList,
  endpointCidrs ? [ ],
}:

let
  apnicSnapshotDate = "20260906";
  apnicSnapshotHash = "sha256-AGfq79JNZE91hF2MsS+7FWNcQE/FrrdbYtva8FIBZOc=";
in
stdenvNoCC.mkDerivation {
  pname = "nchnroutes";
  version = "unstable-2022-08-02";
  src = source;

  apnicDelegated = fetchurl {
    url = "https://ftp.apnic.net/stats/apnic/${builtins.substring 0 4 apnicSnapshotDate}/delegated-apnic-${apnicSnapshotDate}.gz";
    hash = apnicSnapshotHash;
    downloadToTemp = true;
    postFetch = ''
      ${gzip}/bin/gzip -dc "$downloadedFile" > "$out"
    '';
  };

  nativeBuildInputs = [ python3 ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    cp "$apnicDelegated" delegated-apnic-latest
    cp "${chinaIpList}/china_ip_list.txt" china_ip_list.txt
    python3 produce.py \
      --next tun0 \
      --exclude ${builtins.concatStringsSep " " endpointCidrs}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm0444 routes4.conf "$out/etc/bird/nchnroutes4.conf"
    install -Dm0444 routes6.conf "$out/etc/bird/nchnroutes6.conf"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    python3 - "$out/etc/bird/nchnroutes4.conf" ${builtins.concatStringsSep " " endpointCidrs} <<'PY'
    import ipaddress
    import re
    import sys

    route_file = sys.argv[1]
    pattern = re.compile(r'^route ([0-9.]+/[0-9]+) via "tun0";$')
    networks = []
    with open(route_file, encoding="ascii") as routes:
        for number, line in enumerate(routes, 1):
            match = pattern.fullmatch(line.rstrip("\n"))
            if match is None:
                raise SystemExit(f"invalid route at line {number}: {line.rstrip()}")
            networks.append(ipaddress.ip_network(match.group(1)))

    if not 5000 <= len(networks) <= 30000:
        raise SystemExit(f"unexpected IPv4 route count: {len(networks)}")

    excluded = [
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("100.64.0.0/10"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
    ] + [ipaddress.ip_network(cidr) for cidr in sys.argv[2:]]
    for network in networks:
        if any(network.overlaps(prefix) for prefix in excluded):
            raise SystemExit(f"route overlaps excluded prefix: {network}")

    def routed(address):
        ip = ipaddress.ip_address(address)
        return any(ip in network for network in networks)

    if not routed("1.1.1.1"):
        raise SystemExit("foreign probe 1.1.1.1 is not routed")
    if routed("223.5.5.5"):
        raise SystemExit("China probe 223.5.5.5 is routed")
    PY
  '';
}
