#!/bin/bash
#Utility for managing encrypted data files

#List of secrets
SECRETFILES="secret.env
kubeconfig
kubeconfig-dev
"

echo "ASDC DronesVL encrypted secret files"
echo " Requires: "
echo ""
echo " 1) GitHub account authorised to access the private repo at AuScalableDroneCloud/secrets"
echo " 2) The encryption key pair shared with team members to decrypt this file"
echo "    (by default we use ${KEYPAIR} key pair,"
echo "     defined in KEYPAIR=FN in DronesVL/settings.env)"
echo " see https://dashboard.rc.nectar.org.au/project/key_pairs)"
echo ""
echo " Usage:"
echo ""
echo " Simply run  ./crypt.sh"
echo ""
echo " - If the unencrypted secrets are not present,"
echo "   or the encrypted files are newer, "
echo "   they will be decrypted"
echo " - If the unencrypted secrets ARE present,"
echo "   they will be re-encrypted, ready to be committed and pushed"
echo " - If the 'push' arg is provided,"
echo "   changes will be committed and pushed automatically"

#Use the KEYPAIR from settings or default to ASDC_ODM
KEYPAIR="${KEYPAIR:-ASDC_ODM}"

#Public key
PUBKEY=${KEYPAIR}.pub
#Private key
PRIVKEY=secrets/${KEYPAIR}.pem

#If private key file doesn't exist, inform user
if [ ! -f "${PRIVKEY}" ];
then
  echo "Please download the private key and store here as: ${PRIVKEY}"
  exit
fi

#Ensure not widely readable
chmod 600 ${PRIVKEY}

#Get the repo and update
pushd secrets
git clone git@github.com:AuScalableDroneCloud/secrets.git encrypted
cd encrypted
git pull
popd

#Get the utility to use ssh key for encrypt/decrypt
#https://github.com/S2-/sshenc.sh
if [ ! -f sshenc.sh ]; then
  curl -O https://sshenc.sh/sshenc.sh
  chmod +x sshenc.sh
fi

#Process each file in list
for secret in $SECRETFILES
do
  enc=secrets/encrypted/$secret.enc
  dec=secrets/$secret

  #If decrypted file doesn't exist, or encrypted is newer than
  if [ ! -f "$dec" ] || [ $enc -nt $dec ];
  then
    #Decrypt the file
    echo "DECRYPTING $secret"
    ./sshenc.sh -s ${PRIVKEY} < $enc > $dec
  else
    #Encrypt with public key:
    echo "ENCRYPTING $secret"
    ./sshenc.sh -p ${PUBKEY} < $dec > $enc
  fi
  #Ensure not widely readable
  chmod 600 $dec
done

#Secret repo update...
if [ "$1" = "push" ]; then
  pushd secrets/encrypted
  git stage *
  git commit -m "Updating secrets"
  git push
  popd
fi

