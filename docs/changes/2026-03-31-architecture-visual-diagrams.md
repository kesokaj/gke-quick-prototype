# Architecture Visual Diagrams Addition

**Date:** 2026-03-31

## Summary
Added comprehensive Mermaid visual flowcharts to the project documentation to illustrate system architecture, lifecycle transitions, and network isolation boundaries. This provides a clearer, at-a-glance understanding of how the different layers of the infrastructure interact.

## Modified Files
- `README.md` (root): Added high-level GCP infrastructure and component architecture diagram.
- `app/README.md`: Added sequences for the warm pool control lifecycle and a diagram illustrating strict gVisor pod network isolation boundaries.
- `docs/specs/sandbox/integration-spec.md`: Replaced text-based lifecycle phases with a visual Mermaid flowchart detailing state transitions.

## Verification
- Diagram syntax was validated to be correct Mermaid JS format.
- Layered separation of documentation was verified (Infrastructure at root, Application-level details in `app/`).
