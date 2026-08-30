
› every startup of leaselinkd should log version and some config info on startup.
  leaselinkd should report configuration if it recived SIGUSR1
  leaselinkd should report some basic metrics if it recived SIGUSR1 (call count, runtime, api call counts)

  1. add --loglevel flag that takes ERROR, WARN, INFO or DEBUG for leaselinkd and `kea-leaselink`
  2. DEBUG this should log important configuration on startup, and emit key messages during operations. Enough to debug config,
  startup, payloads, and any triggers.
  3. ERROR should log any error or failure condition
  4. WARN should log any incomplete/irregular or insufficient information to proceed.
  5. INFO should give general information about operation, lease operations, some detail of the host being operated on. unbound-
  mgr should report the lease operation, and the call to unbound
