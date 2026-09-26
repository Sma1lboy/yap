# design/screenshots

Product screenshots for GitHub Releases and the READMEs: Home, the Yap Cloud page (`account-*`, Models > Cloud > Yap Cloud) and Modes, light, English (`-en`) and Chinese (`-zh`). 1800×1500 PNG, the main window at its default size (900×750 pt) at 2x.

They're `make ui-snapshots` renders (the same fake data as `make mock`: signed in with $4.21, 20 mixed Chinese–English transcripts, five modes), cropped to the window's height:

```sh
make ui-snapshots
for p in home account modes; do
  sips -c 1500 1800 --cropOffset 1 1 /tmp/yap-ui/snapshots/page-$p-light.png    --out design/screenshots/$p-en.png
  sips -c 1500 1800 --cropOffset 1 1 /tmp/yap-ui/snapshots/page-$p-zh-light.png --out design/screenshots/$p-zh.png
done
```
