document sources: [unbound](https://docs.opnsense.org/development/api/core/unbound.html)

CRUD Tabel 

Operation,HTTP Method,API Endpoint,Description
Add Override,POST,/api/unbound/settings/add_host_override,"Creates a new host entry (A, AAAA, MX)."
Get Override,GET,/api/unbound/settings/get_host_override/$uuid,Retrieves an existing override by its UUID.
Update Override,POST,/api/unbound/settings/set_host_override/$uuid,Modifies an existing host override.
Delete Override,POST,/api/unbound/settings/del_host_override/$uuid,Deletes a host override.
Apply Changes,POST,/api/unbound/service/reconfigure,Required. Reloads Unbound so updates take effect.

validating unbound
To request a list of all Unbound host overrides, send a POST or GET request to the /api/unbound/settings/search_host_override endpoint.



examples:

Adding a host override:
curl -k -u "YOUR_KEY":"YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{
        "host": {
          "enabled": "1",
          "hostname": "app",
          "domain": "example.com",
          "rr": "A",
          "server": "192.168.1.50",
          "description": "Internal Custom Domain"
        }
      }' \
  https://<opnsense-ip>/api/unbound/settings/add_host_override

validating existing overrides
curl -k -u "YOUR_API_KEY":"YOUR_API_SECRET" \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{
        "current": 1,
        "rowCount": -1,
        "searchPhrase": "",
        "sort": {}
      }' \
  https://<opnsense-ip>/api/unbound/settings/search_host_override

tail call to reconfigure unbound:
curl -k -u "YOUR_KEY":"YOUR_SECRET" \
  -X POST \
  https://<opnsense-ip>/api/unbound/service/reconfigure
