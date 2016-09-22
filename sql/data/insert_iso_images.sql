INSERT INTO iso_images
(id,name,description,arch,xml,xml_volume,url)
VALUES(1,'Debian Jessie 32 bits netinst'
    ,'Debian 8.5.0 Jessie 32 bits (netsinst)'
    ,'i386'
    ,'jessie-i386.xml'
    ,'jessie-volume.xml'
    ,'http://cdimage.debian.org/debian-cd/8.6.0/i386/iso-cd/debian-8.6.0-i386-netinst.iso');
INSERT INTO iso_images
(id,name,description,arch,xml,xml_volume,url)
VALUES(2,'Ubuntu Trusty 32 bits','Ubuntu 14.04 LTS Trusty 32 bits'
    ,'i386'
    ,'trusty-i386.xml'
    ,'trusty-volume.xml'
    ,'http://releases.ubuntu.com/16.04/ubuntu-16.04-desktop-i386.iso');

INSERT INTO iso_images
(id,name,description,arch,xml,xml_volume,url)
VALUES(3,'Ubuntu Xenial Xerus 32 bits','Ubuntu 16.04 LTS Xenial Xerus 32 bits'
    ,'i386'
    ,'xenial-i386.xml'
    ,'xenial-volume.xml'
    ,'http://releases.ubuntu.com/16.04/ubuntu-16.04-desktop-i386.iso');

INSERT INTO iso_images
(id,name,description,arch,url)
VALUES(4,'Ubuntu Xenial Xerus 64 bits','Ubuntu 16.04 LTS Xenial Xerus 64 bits'
        ,'amd64'
        ,'http://releases.ubuntu.com/16.04/ubuntu-16.04-desktop-amd64.iso');
