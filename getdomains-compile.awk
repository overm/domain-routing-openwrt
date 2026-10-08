# Pure compiler. Input 1: validated upstream nfset list. Input 2: tab-separated
# snapshot from getdomains-runtime.sh. stdout: dnsmasq; -v static_file: nft batch.
function error(message) { print "getdomains: " message > "/dev/stderr"; bad=1 }
function domain(value) {
    value=tolower(value); sub(/\.$/, "", value); sub(/^\./, "", value)
    if (value !~ /^[a-z0-9_][a-z0-9_.-]*$/ || value ~ /\.\./ || length(value)>253)
        error("unsupported domain: " value)
    return value
}
function within(name, parent) {
    return name==parent || (length(name)>length(parent) &&
        substr(name,length(name)-length(parent))=="." parent)
}
function parent_in(name, collection, p) {
    p=name
    while (1) {
        if (p in collection) return 1
        if (!sub(/^[^.]*\./, "", p)) return 0
    }
}
function merge(name, targets, n, a, i, key) {
    n=split(targets,a,",")
    for(i=1;i<=n;i++) {
        if(a[i] !~ /^[46]#[a-zA-Z0-9_]+#[a-zA-Z0-9_]+#[a-zA-Z0-9_]+$/) {
            error("unsupported nft set: " a[i]); continue
        }
        key=name SUBSEP a[i]
        if (!(key in seen)) {
            manual[name]=manual[name] (manual[name]!="" ? "," : "") a[i]
            seen[key]=1
        }
        if (a[i]=="4#inet#fw4#vpn_domains" || a[i]=="6#inet#fw4#vpn_domains6")
            vpn[name]=1
    }
}
FILENAME==ARGV[1] {
    sub(/\r$/, "")
    if ($0 !~ /^nftset=\/[A-Za-z0-9_.-]+\/4#inet#fw4#vpn_domains$/) {
        error("unexpected downloaded list format"); next
    }
    split($0,part,"/"); auto[domain(part[2])]=1
    if (++count>20000) error("too many downloaded domains")
    next
}
{
    split($0,field,"\t")
    if(field[1]=="M") merge(domain(field[2]),field[3])
    else if(field[1]=="X") {
        if(field[2]=="*") override_all=1
        else override[domain(field[2])]=1
    }
    else if(field[1]=="H") {
        name=domain(field[2]); hosts[name SUBSEP field[3]]=1; exact_hosts[name]=1
    }
    else if(field[1]=="P") patterns[(field[2]=="*" ? "*" : domain(field[2])) SUBSEP field[3]]=1
    else if(field[1]=="C") aliases[domain(field[2])]=domain(field[3])
    else if(field[1]=="E") error(field[2])
}
END {
    if (bad) exit 1
    target="4#inet#fw4#vpn_domains"
    if(ipv6==1) target=target ",6#inet#fw4#vpn_domains6"
    for(d in auto) if(!parent_in(d,manual)) effective[d]=target
    for(d in manual) effective[d]=manual[d]
    for(d in effective) {
        print "nftset=/" d "/" effective[d]
        if(wdns!="" && !override_all && !parent_in(d,override)) {
            selected=(d in manual) ? (d in vpn) : 1
            print "server=/" d "/" (selected ? wdns : "#")
        }
    }
    # Local answers do not traverse dnsmasq's upstream-answer nftset hook.
    # Seed their addresses separately, without removing shared learned entries.
    if(static_file!="") {
        printf "" > static_file
        for(p in patterns) {
            split(p,parts,SUBSEP); zone=parts[1]; ip=parts[2]
            if(ip=="0.0.0.0" || ip=="::" || ip=="#" || ip=="") continue
            for(d in effective) if(zone=="*" || within(d,zone) || within(zone,d)) {
                name=(zone=="*" || within(d,zone) ? d : zone)
                if(name in exact_hosts || name in aliases) continue
                best_zone=0
                for(other in patterns) {
                    split(other,z,SUBSEP)
                    if(z[1]!="*" && within(name,z[1]) && length(z[1])>best_zone) best_zone=length(z[1])
                }
                if((zone=="*" ? 0 : length(zone))>=best_zone) hosts[name SUBSEP ip]=1
            }
        }
        # Resolve local CNAME chains without issuing DNS queries or altering UCI.
        for(pass=0;pass<20;pass++) {
            added=0
            for(alias in aliases) for(h in hosts) {
                split(h,parts,SUBSEP)
                key=alias SUBSEP parts[2]
                if(parts[1]==aliases[alias] && !(key in hosts)) { hosts[key]=1; added++ }
            }
            if(!added) break
        }
        for(h in hosts) {
            split(h,parts,SUBSEP); name=parts[1]; ip=parts[2]; best=""
            for(d in effective) if(within(name,d) && length(d)>length(best)) best=d
            if(best=="") continue
            n=split(effective[best],a,",")
            for(i=1;i<=n;i++) {
                split(a[i],t,"#")
                if((t[1]==4 && ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ||
                   (t[1]==6 && ip !~ /^[0-9a-fA-F:]+$/)) continue
                # Only own sets have a known timeout/ownership contract.
                if(t[2]!="inet" || t[3]!="fw4" ||
                   (t[4]!="vpn_domains" && t[4]!="vpn_domains6")) continue
                key=t[4] SUBSEP ip
                if(!(key in seeded)) {
                    print "add element inet fw4 " t[4] " { " ip " timeout 2d }" > static_file
                    seeded[key]=1
                }
            }
        }
        close(static_file)
    }
}
