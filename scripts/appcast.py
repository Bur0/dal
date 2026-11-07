#!/usr/bin/env python3
"""Prepend a release <item> to appcast.xml.

usage: appcast.py appcast.xml VERSION BUILD URL "sparkle:edSignature=... length=..." "notes"
"""
import sys, html, email.utils

path, version, build, url, signature, notes = sys.argv[1:7]
notes_html = "".join(f"<li>{html.escape(line.lstrip('-* ').strip())}</li>" for line in notes.splitlines() if line.strip())
item = f"""    <item>
      <title>Dal {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>{notes_html}</ul>]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature.strip()} />
    </item>
"""
text = open(path).read()
marker = "    <language>en</language>\n"
assert marker in text, "appcast.xml is missing the <language> line"
text = text.replace(marker, marker + item, 1)
open(path, "w").write(text)
print(f"appcast: added {version} ({build})")
