When libdhcp_run_script.so executes your script (kea-leaselink), Kea passes the Hook Point / Event Name as the first command-line argument ($1). All contextual data for that event is passed via Environment Variables.

Event Type ($1),Trigger Condition,Key Environment Variables Provided
leases4_committed / leases6_committed,"A lease has been assigned, updated, or renewed and saved to the DB.","LEASES4_SIZE, LEASES4_AT0_ADDRESS, LEASES4_AT0_HWADDR, LEASES4_AT0_HOSTNAME, LEASES4_AT0_CLTT, LEASES4_AT0_VALID_LIFETIME (Note: Uses array indexing AT0, AT1 if batch committed)."
lease4_renew / lease6_renew,A client requests to extend its existing active lease.,"KEA_LEASE4_ADDRESS, KEA_LEASE4_HWADDR, KEA_LEASE4_HOSTNAME, KEA_LEASE4_VALID_LIFETIME, KEA_QUERY4_TYPE, KEA_QUERY4_CIADDR."
lease4_release / lease6_release,"Client explicitly relinquishes its lease (e.g., system shutdown or disconnect).","KEA_LEASE4_ADDRESS, KEA_LEASE4_HWADDR, KEA_LEASE4_HOSTNAME, KEA_REMOVE_LEASE."
lease4_expire / lease6_expire,A lease timer expires without being renewed by the client.,"KEA_LEASE4_ADDRESS, KEA_LEASE4_HWADDR, KEA_LEASE4_HOSTNAME, KEA_LEASE4_IS_EXPIRED."
lease4_decline / lease6_decline,"Client refuses the offered IP (e.g., duplicate IP detection / ARP probe collision).","KEA_LEASE4_ADDRESS, KEA_LEASE4_HWADDR, KEA_LEASE4_STATE."
lease4_recover / lease6_recover,An expired/declined lease is reclaimed and made available to the pool.,"KEA_LEASE4_ADDRESS, KEA_LEASE4_STATE."


When processing these events inside kea-leaselink, you inspect these primary environment variables:KEA_LEASE4_ADDRESS / KEA_LEASE6_ADDRESS: The IPv4 or IPv6 address being assigned/handled.KEA_LEASE4_HWADDR: The client's MAC address (e.g., 00:11:22:33:44:55).  KEA_LEASE4_HOSTNAME: The hostname supplied by the client or set by static mapping.KEA_LEASE4_VALID_LIFETIME: Lease length in seconds.KEA_LEASE4_CLIENT_LAST_TRANSMISSION: Epoch timestamp of the client's last communication.

