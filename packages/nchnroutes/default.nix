{
  fetchurl,
  python3,
  stdenvNoCC,
  source,
  chinaIpList,
}:

let
  apnicSnapshotHash = "sha256-h0BeISdobh3pZ0+bYBUKzb4VyU1L4E/7jHhznqAE3MM=";
  endpointMap = {
    ark = "107.189.6.180";
    courier = "89.208.240.145";
    cygnus = "67.230.162.189";
    flint = "103.118.41.228";
    glacier = "1.116.139.81";
    navi = "89.208.253.236";
    octo = "23.247.139.23";
    shuttle = "89.208.241.145";
    speicher = "167.179.83.73";
  };
  serviceBindings = {
    docs = "shuttle";
    git = "flint";
    repo = "navi";
    sanctuary = "flint";
    skin = "courier";
    wiki = "cygnus";
  };
  endpointCidrs = map (address: "${address}/32") (builtins.attrValues endpointMap);
in
stdenvNoCC.mkDerivation {
  pname = "nchnroutes";
  version = "unstable-2022-08-02";
  src = source;

  apnicDelegated = fetchurl {
    url = "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest";
    hash = apnicSnapshotHash;
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

  passthru = {
    inherit endpointMap serviceBindings;
  };
}
