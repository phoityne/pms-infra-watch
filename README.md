# pms-infra-watch
`pms-infra-watch` is one of the internal packages that make up the [`pty-mcp-server`](https://github.com/phoityne/pty-mcp-server) project. 


`pms-infra-watch` is a file-watching component that monitors changes to published resource lists, including `tools`, `prompts/`, and `resources/` directories. When any of these files or directories are modified—such as when new tools are added, prompts are updated, or shared resources are replaced—it automatically detects the changes and sends structured notifications to connected MCP clients.  

 This enables clients to stay up-to-date with the latest tool definitions and related resources without requiring manual refresh or restart. The package is designed for integration into MCP-based development environments, ensuring a seamless and dynamic update workflow.

---

## Package Structure
![Package Structure](https://raw.githubusercontent.com/phoityne/pms-infra-watch/main/docs/01_package_structuer.png)
---

## Module Structure
![Module Structure](https://raw.githubusercontent.com/phoityne/pms-infra-watch/main/docs/02_module_structure.png)

---
