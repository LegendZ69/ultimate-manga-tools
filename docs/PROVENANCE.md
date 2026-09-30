# Workflow provenance

The earlier Scales of Revenge chapter deliveries documented these operations:

1. Inspect the supplied ZIP archives and preserve page order.
2. Translate Japanese dialogue, narration, readable handwriting, and sound effects.
3. Edit the page artwork to place English text.
4. Apply necessary localized redactions.
5. Review lettering, remaining Japanese strokes, and intact panels.
6. Maintain consistent character names and correct known mistakes.
7. Package and verify one CBZ per chapter, then save the deliverables.

The eight delivered chapters contained 72 pages in total. The final CBZs and many
generated page images were recoverable. The visible conversation identified
image-editing and file-saving skills, but did not preserve exact model IDs,
public API calls, reusable application source, or the temporary scripts for that
batch. Older code fragments found in other chapter handoffs are not evidence of
which tools were used for this batch.

This repository is new source code implementing a comparable workflow. Its
Flutter client, archive handling, checkpoint format, Python service, API choices,
tests, and native packaging were newly written for this project. It does not
contain ChatGPT's image-editing model or reproduce its private implementation.
The service uses documented public APIs and requires separately configured access.

The required omissions in the prior deliveries remain part of those files. This
app does not reverse redactions or bypass provider content restrictions.
