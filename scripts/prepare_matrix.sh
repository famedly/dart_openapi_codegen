#!/bin/sh -e
[ -d matrix-doc ] || git clone https://github.com/matrix-org/matrix-doc.git
(
	cd matrix-doc
	./scripts/dump-swagger.py
	sed -i 's`](/`](https://spec.matrix.org/unstable/`g' scripts/swagger/api-docs.json
)
ln -sf matrix-doc/scripts/swagger/api-docs.json matrix.json
