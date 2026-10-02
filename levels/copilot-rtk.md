RTK is installed. Run supported shell commands through rtk by prefixing them, e.g. `rtk git status`, `rtk dotnet build`, `rtk dotnet test`, `rtk npm install`.
- Use it for: git, dotnet, npm, pnpm, pip, cargo, go, pytest, jest, ls, grep.
- Don't prefix: commands with pipes, && or ;, cd or variable assignments, interactive or long-running commands (servers, watch modes, REPLs), shell-specific cmdlets, or commands that already start with rtk.
- If rtk is missing or doesn't support a command, run the plain command.
