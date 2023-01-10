flakes@{ dependencyDagOfSubmodule, ... }:
{ config
, lib
, ... }:
with dependencyDagOfSubmodule.lib.bake lib;

let
  cfg = config.networking.nftables.firewall;
  ruleTypes = [ "rule" "policy" ];
in {

  imports = [
    (import ./nftables-chains.nix flakes)
  ];

  options.networking.nftables.firewall = {

    enable = mkEnableOption (mdDoc "the zoned nftables based firewall");

    zones = mkOption {
      type = types.dependencyDagOfSubmodule ({ name, config, ... }: {
        options = {
          assertions = mkOption {
            type = with types; listOf attrs;
            internal = true;
          };
          name = mkOption {
            type = types.str;
            internal = true;
          };
          hasExpressions = mkOption {
            type = types.bool;
            internal = true;
          };
          localZone = mkOption {
            type = types.bool;
            default = false;
          };
          parent = mkOption {
            type = with types; nullOr str;
            default = null;
          };
          interfaces = mkOption {
            type = with types; listOf str;
            default = [];
          };
          ipv4Addresses = mkOption {
            type = with types; listOf str;
            default = [];
            example = [ "192.168.0.0/24" ];
          };
          ipv6Addresses = mkOption {
            type = with types; listOf str;
            default = [];
            example = [ "2042::/16" ];
          };
          ingressExpression = mkOption {
            type = types.listOf types.str;
            default = [];
          };
          egressExpression = mkOption {
            type = types.listOf types.str;
            default = [];
          };
        };
        config = with config; {
          assertions = flatten [
            {
              assertion = length ingressExpression == length egressExpression;
              message = "You need to specify the same number of ingress and egress expressions";
            }
            {
              assertion = (localZone || hasExpressions) && ! (localZone && hasExpressions);
              message = "Each zone has to either be the local zone or needs to be defined by ingress and egress expressions";
            }
            {
              assertion = localZone -> isNull parent;
              message = "The local zone cannot have any parent defined";
            }
            {
              assertion = isNull parent || hasAttr parent cfg.zones;
              message = "Zone specified as child of zone '${parent}', but no such zone is defined";
            }
          ];
          name = name;
          hasExpressions = (length ingressExpression > 0) && (length egressExpression > 0);
          ingressExpression = mkMerge [
            (mkIf (length interfaces >= 1) [ "iifname { ${concatStringsSep ", " interfaces} }" ])
            (mkIf (length ipv6Addresses >= 1) [ "ip6 saddr { ${concatStringsSep ", " ipv6Addresses} }" ])
            (mkIf (length ipv4Addresses >= 1) [ "ip saddr { ${concatStringsSep ", " ipv4Addresses} }" ])
          ];
          egressExpression = mkMerge [
            (mkIf (length interfaces >= 1) [ "oifname { ${concatStringsSep ", " interfaces} }" ])
            (mkIf (length ipv6Addresses >= 1) [ "ip6 daddr { ${concatStringsSep ", " ipv6Addresses} }" ])
            (mkIf (length ipv4Addresses >= 1) [ "ip daddr { ${concatStringsSep ", " ipv4Addresses} }" ])
          ];
        };
      });
    };

    rules = let
      portRange = types.submodule {
        options = {
          from = mkOption { type = types.port; };
          to = mkOption { type = types.port; };
        };
      };
    in mkOption {
      type = types.dependencyDagOfSubmodule ({ name, ... }: {
        options = with types; {
          name = mkOption {
            type = str;
            internal = true;
          };
          from = mkOption {
            type = either (enum [ "all" ]) (listOf str);
          };
          to = mkOption {
            type = either (enum [ "all" ]) (listOf str);
          };
          ruleType = mkOption {
            type = enum ruleTypes;
            default = "rule";
            description = mdDoc ''
              The type of the rule specifies when rules are applied.
              Rules of the type `policy` are applied after all rules of the type
              `policy` were.

              Usually most rules are of the type `rule`, `policy` is mostly
              intended to specify special drop/reject rules.
            '';
          };
          allowedTCPPorts = mkOption {
            type = listOf int;
            default = [];
          };
          allowedUDPPorts = mkOption {
            type = listOf int;
            default = [];
          };
          allowedTCPPortRanges = mkOption {
            type = listOf portRange;
            default = [];
            example = literalExpression "[ { from = 1337; to = 1347; } ]";
          };
          allowedUDPPortRanges = mkOption {
            type = listOf portRange;
            default = [];
            example = literalExpression "[ { from = 55000; to = 56000; } ]";
          };
          verdict = mkOption {
            type = nullOr (enum [ "accept" "drop" "reject" ]);
            default = null;
          };
          masquerade = mkOption {
            type = types.bool;
            default = false;
            description = mdDoc ''
              This option currently generates output that may be broken.
              Use at your own risk!
            '';
            internal = true;
          };
          extraLines = mkOption {
            type = types.listOf config.build.nftables-ruleType;
            default = [];
          };
        };
        config.name = name;
      });
      default = {};
    };

  };

  config = let

    toPortList = ports: assert length ports > 0; "{ ${concatStringsSep ", " (map toString ports)} }";

    toRuleName = rule: "rule-${rule.name}";
    toTraverseName = from: matchFromSubzones: to: matchToSubzones: ruleType: let
      zoneName = zone: replaceStrings ["-"] ["--"] zone.name;
      zoneSpec = zone: match: "${zoneName zone}-${if match then "subzones" else "zone"}";
    in "traverse-from-${zoneSpec from matchFromSubzones}-to-${zoneSpec to matchToSubzones}-${ruleType}";

    concatNonEmptyStringsSep = sep: strings: pipe strings [
      (filter (x: x != null))
      (filter (x: stringLength x > 0))
      (concatStringsSep sep)
    ];

    zones = filterAttrs (_: zone: zone.enable) cfg.zones;
    sortedZones = types.dependencyDagOfSubmodule.toOrderedList cfg.zones;

    allZone = {
      name = "all";
      interfaces = [];
      ingressExpression = [];
      egressExpression = [];
      localZone = true;
    };

    lookupZones = zoneNames: if zoneNames == "all" then singleton allZone else map (x: zones.${x}) zoneNames;
    zoneInList = zone: zoneNames: if zone.name == "all" then zoneNames == "all" else isList zoneNames && elem zone.name zoneNames;

    localZone = head (filter (x: x.localZone) sortedZones);

    rules = pipe cfg.rules [
      types.dependencyDagOfSubmodule.toOrderedList
    ];

    perRule = filterFunc: pipe rules [ (filter filterFunc) forEach ];
    perZone = filterFunc: pipe sortedZones [ (filter filterFunc) forEach ];

    childZones = parent:
      if parent.name == "all"
      then filter (x: x.name != "all" && ! x.localZone && isNull x.parent) sortedZones
      else filter (x: x.parent == parent.name) sortedZones;

  in mkIf cfg.enable rec {

    assertions = flatten [
      (map (zone: zone.assertions) sortedZones)
      {
        assertion = (count (x: x.localZone) sortedZones) == 1;
        message = "There needs to exist exactly one localZone.";
      }
    ];

    networking.nftables.firewall.zones.fw = {
      localZone = mkDefault true;
    };

    networking.nftables.firewall.rules.ssh = {
      early = true;
      after = [ "ct" ];
      from = "all";
      to = [ "fw" ];
      allowedTCPPorts = config.services.openssh.ports;
    };
    networking.nftables.firewall.rules.icmp = {
      early = true;
      after = [ "ct" "ssh" ];
      from = "all";
      to = [ "fw" ];
      extraLines = [
        "ip6 nexthdr icmpv6 icmpv6 type { echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept"
        "ip protocol icmp icmp type { echo-request, router-advertisement } accept"
        "ip6 saddr fe80::/10 ip6 daddr fe80::/10 udp dport 546 accept"
      ];
    };

    networking.nftables.chains = let
      hookRule = hook: {
        after = mkForce [ "start" ];
        before = mkForce [ "veryEarly" ];
        rules = singleton hook;
      };
      dropRule = {
        after = mkForce [ "veryLate" ];
        before = mkForce [ "end" ];
        rules = singleton "counter drop";
      };
      conntrackRule = {
        after = mkForce [ "veryEarly" ];
        before = [ "early" ];
        rules = [
          "ct state {established, related} accept"
          "ct state invalid drop"
        ];
      };
      traversalChains = fromZone: toZone:
        (forEach ruleTypes (ruleType:
          (forEach [true false] (matchFromSubzones:
            (forEach [true false] (matchToSubzones:
              {
                name = toTraverseName fromZone matchFromSubzones toZone matchToSubzones ruleType;
                value.generated.rules = concatLists [

                  (optionals matchFromSubzones
                    (concatLists (forEach (childZones fromZone) (childZone:
                      (forEach childZone.ingressExpression (onExpression: {
                        inherit onExpression;
                        jump = toTraverseName childZone true toZone matchToSubzones ruleType;
                      }))
                    )))
                  )

                  (optionals matchToSubzones
                    (concatLists (forEach (childZones toZone) (childZone:
                      (forEach childZone.egressExpression (onExpression: {
                        inherit onExpression;
                        jump = toTraverseName fromZone false childZone true ruleType;
                      }))
                    )))
                  )

                  (optional (matchFromSubzones || matchToSubzones) {
                    jump = toTraverseName fromZone false toZone false ruleType;
                  })

                  (optionals (!(matchFromSubzones || matchToSubzones))
                    (perRule (r: zoneInList fromZone r.from && zoneInList toZone r.to && r.ruleType == ruleType) (rule: {
                      jump = toRuleName rule;
                    }))
                  )

                ];
              }
            ))
          ))
        ));
    in {

      input.hook = hookRule "type filter hook input priority 0; policy drop";
      input.loopback = {
        after = mkForce [ "veryEarly" ];
        before = [ "conntrack" "early" ];
        rules = singleton "iifname { lo } accept";
      };
      input.conntrack = conntrackRule;
      input.generated.rules = concatLists (forEach ruleTypes (ruleType: [
        { jump = toTraverseName allZone true localZone true ruleType; }
        { jump = toTraverseName allZone true allZone false ruleType; }
      ]));
      input.drop = dropRule;

      prerouting.hook = hookRule "type nat hook prerouting priority dstnat;";

      postrouting.hook = hookRule "type nat hook postrouting priority srcnat;";
      postrouting.generated.rules = pipe rules [
        (filter (x: x.masquerade or false))
        (concatMap (rule: forEach (lookupZones rule.from) (from: rule // { inherit from; })))
        (concatMap (rule: forEach (lookupZones rule.to) (to: rule // { inherit to; })))
        (map (rule: [
          "meta protocol ip"
          (head rule.from.ingressExpression)
          (head rule.to.egressExpression)
          "masquerade random"
        ]))
      ];

      forward.hook = hookRule "type filter hook forward priority 0; policy drop;";
      forward.conntrack = conntrackRule;
      forward.generated.rules = concatLists (forEach ruleTypes (ruleType: [
        { jump = toTraverseName allZone true allZone true ruleType; }
      ]));
      forward.drop = dropRule;

    } // (listToAttrs (flatten [

      (perZone (_: true) (zone: [
        (traversalChains zone allZone)
        (traversalChains allZone zone)
      ]))

      (perZone (_: true) (fromZone: (perZone (_: true) (toZone: traversalChains fromZone toZone))))

      (traversalChains allZone allZone)

      (perRule (_: true) (rule: {
        name = toRuleName rule;
        value.generated.rules = let
          formatPortRange = { from, to }: "${toString from}-${toString to}";
          allowedTCPPorts = rule.allowedTCPPorts ++ forEach rule.allowedTCPPortRanges formatPortRange;
          allowedUDPPorts = rule.allowedUDPPorts ++ forEach rule.allowedUDPPortRanges formatPortRange;
        in [
          (optionalString (allowedTCPPorts!=[]) "tcp dport ${toPortList allowedTCPPorts} accept")
          (optionalString (allowedUDPPorts!=[]) "udp dport ${toPortList allowedUDPPorts} accept")
          (optionalString (rule.verdict!=null) rule.verdict)
        ] ++ rule.extraLines;
      }))

    ]));

    # enable ntf based firewall
    networking.nftables.enable = true;

    # disable iptables based firewall
    networking.firewall.enable = false;
  };

}
