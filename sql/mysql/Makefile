SQL:= ../sqlite/bases.sql ../sqlite/iso_images.sql ../sqlite/lxc_templates.sql ../sqlite/requests.sql ../sqlite/file_base_images.sql ../sqlite/domains_network.sql ../sqlite/messages.sql ../sqlite/networks.sql ../sqlite/domains.sql ../sqlite/users.sql ../sqlite/iptables.sql ../sqlite/domain_drivers_options.sql ../sqlite/domain_drivers_types.sql ../sqlite/vms.sql ../sqlite/base_xml.sql

ALL: $(SQL)

../sqlite/%.sql: %.sql
	mysql2sqlite $^ | egrep -v "(^PRAGMA|TRANSACTION)" | perl -ne 's/DEFAULT now\(\)/DEFAULT CURRENT_TIME/i; print $_' > $@

clean:
	rm $(SQL)
