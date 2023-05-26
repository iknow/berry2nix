#!/usr/bin/env bash

target="tests/$1"
mkdir "$target"
cat > "$target/package.json" <<EOF
{
  "name": "$1"
}
EOF

yarnPath=$(find .yarn/releases -type f | head -1)

cat > "$target/.yarnrc.yml" <<EOF
nodeLinker: pnp

yarnPath: $yarnPath
EOF

mkdir "$target/.yarn"
ln -s ../../../.yarn/releases "$target/.yarn"

# indicate that this is not a workspace
touch "$target/yarn.lock"
