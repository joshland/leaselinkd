# Prompt History

Chronological record of the user requests that guided this project.

## 1. Initial implementation

> You gave me some genius zig-0.16 before, can you do it again?
>
> references/ contains reference docs, please investigate them.
>
> These are my working docs.
> AGENTS.md
> ARCHITECTURE.md
> CONFIGS.md
> kea-notes.md
> MEMORY.md
> OVERVIEW.md
> PROCESSES.md
> prompt1.md
> SERVERS.md
> unbound.md
>
> please implement this project

## 2. Test coverage

> can you make some tests, and test at least `kea-leaselink` and `leaselinkd`

## 3. Manager runtime features

> ok, let's add the health-check/backoff loop, TCP listener, and deferred reconfigure throttling. to the leaselinkd

## 4. Arch package failure

> ok, I deployed the to my server, and use makepkg -si on it:
>
> `zig-out/bin/leaselinkd` was built, but `makepkg -si` failed in `package()` with:
>
> ```text
> install: cannot stat 'zig-out/bin/leaselinkd': No such file or directory
> ```

## 5. Logging and signal reporting

> every startup of leaselinkd should log version and some config info on startup.
> leaselinkd should report configuration if it recived SIGUSR1
> leaselinkd should report some basic metrics if it recived SIGUSR1 (call count, runtime, api call counts)
>
> 1. add --loglevel flag that takes ERROR, WARN, INFO or DEBUG for leaselinkd and `kea-leaselink`
> 2. DEBUG this should log important configuration on startup, and emit key messages during operations. Enough to debug config, startup, payloads, and any triggers.
> 3. ERROR should log any error or failure condition
> 4. WARN should log any incomplete/irregular or insufficient information to proceed.
> 5. INFO should give general information about operation, lease operations, some detail of the host being operated on. leaselinkd should report the lease operation, and the call to unbound

## 6. Version 1.1

> increment the version to 1.1

## 7. README

> make a README.md

## 8. Native HTTP client

> we should eliminate the use of curl and implement native API calls in zig

## 9. Unprivileged service account

> let's add a packaging requirement
>
> we need an leaselinkd user and group, we should set the ownershup of the directories to the user,and we should run the leaselinkd unpriviledged

## 10. Version 1.5

> increment the version 1.5

## 11. Agent and memory guidance

> please update AGENTS.md and MEMORY.md with crucial details

## 12. Changelog

> write a changelog that shows all of the development steps

## 13. Installed permission policy

> now that we're creating a user, ensure that directories and folder have the correct permissions on install.
>
> add writing the changelog to either AGENTS or MEMORY

## 14. `kea-leaselink` configuration access

> if kea installed on the node we install on, we should ensure that the kea user can read the hook config.

## 15. Version 1.5.1

> update version to 1.5.1

## 16. CLI validation and API test

> leaselinkd needs --config-check flag. It need to cehck the config
>
> leaselinkd needs --api-test flag. it should verify from the CLI that it can connect to unbound and trigger a restart

## 17. Dependency coverage

> We should ensure that all of our dependencies are coverded for installation

## 18. Prompt-history record

> write my complete prompt history to project/prompts.md
