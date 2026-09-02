#!/usr/local/bin/php
<?php
/* Run as root on OPNsense.  Default re-runs never rotate an existing key. */
if (PHP_SAPI !== 'cli' || posix_geteuid() !== 0) { fwrite(STDERR, "Run as root on OPNsense.\n"); exit(1); }
require_once('/usr/local/etc/inc/config.inc');
require_once('/usr/local/etc/inc/auth.inc');
const VERSION='3.0.4'; const GROUP_NAME='unbound_api'; const USER_NAME='leaselinkd'; const BOOTSTRAP_FILE='/root/leaselinkd-bootstrap.json';
$privileges=['page-diagnostics-health','page-services-unbound','page-services-dnsresolver-acls','page-services-dnsresolver-advanced','page-services-dnsresolver-overrides','page-services-dnsresolver','page-system-status'];
$action=$argv[1]??'provision'; $argument=$argv[2]??'';
if(!in_array($action,['provision','--rotate-api-key','--revoke-api-key'],true)||($action==='--revoke-api-key'&&$argument==='')||count($argv)>($action==='--revoke-api-key'?3:2)){fwrite(STDERR,"Usage: php provision-opnsense-leaselinkd.php [--rotate-api-key | --revoke-api-key API_KEY]\n");exit(64);}
printf("OPNsense leaselinkd provisioner v%s starting.\n", VERSION);

function find_name(array $items,string $name): ?array { foreach($items as $i=>$v) if(($v['name']??'')===$name)return ['i'=>$i,'v'=>$v]; return null; }
function find_ref(array $items,string $ref): ?array { foreach($items as $v)if(($v['refid']??'')===$ref)return $v; return null; }
function next_id(string $field): int { global $config; $used=[];$section=$field==='gid'?'group':'user';foreach(($config['system'][$section]??[])as $v)if(isset($v[$field]))$used[(int)$v[$field]]=true;for($i=2000;$i<=65000;$i++)if(!isset($used[$i]))return $i;throw new RuntimeException("No available $field."); }
function random_text(int $n): string { return rtrim(strtr(base64_encode(random_bytes($n)),'+/','-_'),'='); }
function pem(array $item): ?string { $v=$item['crt']??null;if(!is_string($v)||$v==='')return null;return str_contains($v,'-----BEGIN CERTIFICATE-----')?$v:(base64_decode($v,true)?:null); }
function unbound_audit(): int {
 $bad=0; printf("Unbound capability audit:\n");
 if(!is_executable('/usr/local/sbin/configctl')){printf("  FAIL: configctl is unavailable; this firewall does not expose the supported Unbound service interface\n");return 1;}
 $out=[];$code=1;exec('/usr/local/sbin/configctl unbound status 2>&1',$out,$code);$text=implode("\n",$out);
 if($code!==0){printf("  FAIL: Unbound status command failed: %s\n",$text);return 1;}
 if(!preg_match('/\brunning\b/i',$text)){printf("  FAIL: Unbound is not running: %s\n",$text);return 1;}
 printf("  PASS: supported Unbound status interface is present and Unbound is running\n");return $bad;
}
function tls_audit(): int {
 global $config; $bad=0; $pass=static fn($m)=>printf("  PASS: %s\n",$m); $fail=static function($m)use(&$bad){printf("  FAIL: %s\n",$m);$bad++;};
 printf("Web GUI TLS certificate audit:\n"); $ref=$config['system']['webgui']['ssl-certref']??''; $cert=is_string($ref)?find_ref($config['cert']??[],$ref):null;
 if(!$cert||!($server_pem=pem($cert))){$fail('selected Web GUI certificate cannot be read');return $bad;}
 $server=openssl_x509_parse($server_pem,false);if($server===false){$fail('selected Web GUI certificate cannot be parsed');return $bad;}
 printf("  Selected certificate: %s (%s)\n",$cert['descr']??'(unnamed)',$ref);printf("  Subject: %s\n",$server['name']??'(unknown)');
 if(($server['validFrom_time_t']??PHP_INT_MAX)<=time()&&time()<($server['validTo_time_t']??0))$pass('server certificate is currently valid');else $fail('server certificate is expired or not yet valid');
 $ext=$server['extensions']??[];
 if(stripos($ext['basicConstraints']??'','CA:FALSE')!==false)$pass('server Basic Constraints is CA:FALSE');else $fail('server certificate must have Basic Constraints CA:FALSE');
 if(stripos($ext['extendedKeyUsage']??'','TLS Web Server Authentication')!==false||stripos($ext['extendedKeyUsage']??'','serverAuth')!==false)$pass('server permits TLS Web Server Authentication');else $fail('server lacks TLS Web Server Authentication extended key usage');
 if(stripos($ext['keyUsage']??'','Digital Signature')!==false)$pass('server Key Usage includes Digital Signature');else $fail('server Key Usage lacks Digital Signature');
 preg_match_all('/(?:^|,\s*)DNS:([^,\s]+)/i',$ext['subjectAltName']??'', $dns);
 if(!empty($dns[1]))$pass('DNS SANs for the Zig API URL: '.implode(', ',$dns[1]));else $fail('server has no DNS SAN; Zig 0.16 cannot use an IP-only SAN');
 $ca=isset($cert['caref'])?find_ref($config['ca']??[],$cert['caref']):null;
 if(!$ca||!($ca_pem=pem($ca))){$fail('server certificate has no readable issuing CA reference');return $bad;}
 $ca_info=openssl_x509_parse($ca_pem,false);printf("  Issuing CA: %s (%s)\n",$ca['descr']??'(unnamed)',$cert['caref']);
 if($ca_info!==false&&stripos($ca_info['extensions']['basicConstraints']??'','CA:TRUE')!==false)$pass('issuing CA Basic Constraints is CA:TRUE');else $fail('issuing CA Basic Constraints is not CA:TRUE');
 $cf=tempnam(sys_get_temp_dir(),'ubm-ca-');$sf=tempnam(sys_get_temp_dir(),'ubm-cert-');if(!$cf||!$sf){$fail('cannot create temporary files for chain validation');return $bad;}
 try { file_put_contents($cf,$ca_pem,LOCK_EX);file_put_contents($sf,$server_pem,LOCK_EX);$ca_text=[];$ca_code=1;exec('openssl x509 -in '.escapeshellarg($cf).' -noout -text 2>&1',$ca_text,$ca_code);if($ca_code===0&&preg_match('/Basic Constraints:\s*critical\s*\R\s*CA:TRUE/i',implode("\n",$ca_text)))$pass('issuing CA Basic Constraints is marked critical');else $fail('issuing CA Basic Constraints CA:TRUE is not marked critical');$out=[];$code=1;exec('openssl verify -purpose sslserver -CAfile '.escapeshellarg($cf).' '.escapeshellarg($sf).' 2>&1',$out,$code);if($code===0)$pass('server certificate chains to configured CA');else $fail('server certificate does not chain to configured CA: '.implode('; ',$out)); } finally {@unlink($cf);@unlink($sf);}
 return $bad;
}

$unbound_failures=unbound_audit();if($unbound_failures)exit(2);
$groups=config_read_array('system','group',false);$users=config_read_array('system','user',false);$g=find_name($groups,GROUP_NAME);$u=find_name($users,USER_NAME);$changed=false;$new_user=false;$credential_written=false;
if($action==='--revoke-api-key'&&!$u)throw new RuntimeException('Cannot revoke an API key: the leaselinkd user does not exist.');
if($action!=='--revoke-api-key'&&(!$u||$action==='--rotate-api-key')&&file_exists(BOOTSTRAP_FILE))throw new RuntimeException(BOOTSTRAP_FILE.' exists; transfer or remove it before creating credentials.');
if(!$g){$group=['name'=>GROUP_NAME,'description'=>'Unbound API Access','scope'=>'user','gid'=>(string)next_id('gid'),'member'=>[],'priv'=>$privileges];config_push_array('system','group',$group);$g=['v'=>$group];$changed=true;printf("Created group %s (gid %s).\n",GROUP_NAME,$group['gid']);}
else {$group=$g['v'];$missing=array_diff($privileges,$group['priv']??[]);printf("Existing group %s (gid %s; required privileges %s).\n",GROUP_NAME,$group['gid']??'unknown',$missing?'MISSING: '.implode(', ',$missing):'present');}
if(!$u){$password=random_text(32);$key=base64_encode(random_bytes(60));$secret=base64_encode(random_bytes(60));$user=['name'=>USER_NAME,'descr'=>'LeaseLink','scope'=>'user','uid'=>(string)next_id('uid'),'password'=>password_hash($password,PASSWORD_BCRYPT,['cost'=>11]),'apikeys'=>['item'=>[['key'=>$key,'secret'=>crypt($secret,'$6$')]]]];config_push_array('system','user',$user);$u=['v'=>$user];$new_user=true;$changed=true;printf("Created user %s (uid %s; API keys 1).\n",USER_NAME,$user['uid']);}
else {$user=$u['v'];printf("Existing user %s (uid %s; API keys %d).\n",USER_NAME,$user['uid']??'unknown',count($user['apikeys']['item']??[]));}
$uid=(string)$u['v']['uid'];if(!in_array($uid,$g['v']['member']??[],true)){$gi=find_name(config_read_array('system','group',false),GROUP_NAME)['i'];$config['system']['group'][$gi]['member'][]=$uid;$changed=true;printf("Added user %s to group %s.\n",USER_NAME,GROUP_NAME);}else printf("Group membership: present.\n");
if($action==='--rotate-api-key'&&!$new_user){$ui=find_name(config_read_array('system','user',false),USER_NAME)['i'];$key=base64_encode(random_bytes(60));$secret=base64_encode(random_bytes(60));$config['system']['user'][$ui]['apikeys']['item'][]=['key'=>$key,'secret'=>crypt($secret,'$6$')];$changed=true;$credential_written=true;printf("Created a replacement API key; the previous key remains active until explicitly revoked.\n");}
if($action==='--revoke-api-key'){$ui=find_name(config_read_array('system','user',false),USER_NAME)['i'];$keys=$config['system']['user'][$ui]['apikeys']['item']??[];$remaining=array_values(array_filter($keys,static fn($item)=>($item['key']??'')!==$argument));if(count($remaining)===count($keys))throw new RuntimeException('API key was not found.');if(count($remaining)===0)throw new RuntimeException('Refusing to revoke the final API key. Rotate and validate a replacement first.');$config['system']['user'][$ui]['apikeys']['item']=$remaining;$changed=true;printf("Revoked the requested old API key.\n");}
if($changed){if(write_config('Provision leaselinkd API user and group')===false)throw new RuntimeException('Configuration save failed.');local_group_set(find_name(config_read_array('system','group',false),GROUP_NAME)['v']);}
if($new_user||$credential_written){file_put_contents(BOOTSTRAP_FILE,json_encode(['username'=>USER_NAME,'password'=>$password??null,'api_key'=>$key,'api_secret'=>$secret],JSON_PRETTY_PRINT)."\n",LOCK_EX);chmod(BOOTSTRAP_FILE,0600);printf("One-time credentials written to %s (0600).\n",BOOTSTRAP_FILE);}elseif($action==='provision')printf("No credentials rotated; OPNsense cannot recover existing API secrets.\n");
$failures=tls_audit();if($failures){printf("TLS audit: %d failure(s); correct before using leaselinkd.\n",$failures);exit(2);}printf("TLS audit passed. Use a listed DNS SAN in leaselinkd's API URL.\n");
