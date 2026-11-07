# Public resource provenance

See manifest.json for immutable source URLs and SHA256 values.

- ('ACL4SSR/ACL4SSR', 'CC-BY-SA-4.0', 'https://github.com/ACL4SSR/ACL4SSR/blob/master/LICENCE', 'ACL4SSR-ACL4SSR-LICENSE.txt')
- ('MetaCubeX/meta-rules-dat', 'GPL-3.0', 'https://github.com/MetaCubeX/meta-rules-dat/blob/master/LICENSE', 'MetaCubeX-meta-rules-dat-LICENSE.txt')
- ('Zephyruso/zashboard', 'MIT', 'https://github.com/Zephyruso/zashboard/blob/main/LICENSE', 'Zephyruso-zashboard-LICENSE.txt')

Zashboard dist.zip also includes dist/THIRD_PARTY_NOTICES.md.

## Corresponding editable sources for bundled MRS files

The following original text sources are distributed in `assets/sources/` under
MetaCubeX/meta-rules-dat's GPL-3.0 license, alongside the unmodified MRS files.
All three come from commit `1852a7d214920d77c753293c49eb26a996e52081`:

- `sources/cn-ip.list`: [geo/geoip/cn.list](https://github.com/MetaCubeX/meta-rules-dat/blob/1852a7d214920d77c753293c49eb26a996e52081/geo/geoip/cn.list)
- `sources/ai-foreign.list`: [geo/geosite/category-ai-!cn.list](https://github.com/MetaCubeX/meta-rules-dat/blob/1852a7d214920d77c753293c49eb26a996e52081/geo/geosite/category-ai-!cn.list)
- `sources/tiktok.list`: [geo/geosite/tiktok.list](https://github.com/MetaCubeX/meta-rules-dat/blob/1852a7d214920d77c753293c49eb26a996e52081/geo/geosite/tiktok.list)

Build with the upstream Mihomo converter (`mihomo convert-ruleset BEHAVIOR text
SOURCE DESTINATION`); the converter source and instructions are available at
[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo).
With Mihomo 1.19.33 the supplied sources reproduce all three bundled MRS files
byte-for-byte. `tools/rebuild-rules.sh /path/to/mihomo` verifies this locally.
The runtime installer does not modify or convert these assets.

The ACL4SSR files are already distributed in their editable YAML source form;
retain attribution and CC-BY-SA-4.0 when redistributing or adapting them.
Zashboard is an unmodified MIT-licensed v3.29.1 build; its source is available at
[the v3.29.1 tag](https://github.com/Zephyruso/zashboard/tree/v3.29.1), and its
bundled third-party notices remain inside `webui.zip`.
The project's MIT license applies to original code, not to these resources.

Architecture-specific offline releases additionally carry upstream Mihomo and yq
binaries, licenses, exact source archives and provenance in vendor/. See
vendor/SOURCES.md in the complete release; these files keep their own licenses.
