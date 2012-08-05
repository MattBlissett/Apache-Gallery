{
	if ($STATUS eq 'A' || $STATUS eq 'V' && $LAT ne '' || $LAT ne '') {
		$pin = 'red';
		if ($STATUS eq 'A') { $pin = 'yellow'; }
		if ($STATUS eq 'V') { $pin = 'gray'; }

		$latlong = "";
		if ($LONGR eq 'W') { $latlong .= "-" };
		$latlong .= "${LONG},";
		if ($LATR eq 'S') { $latlong .= "-" };
		$latlong .= "${LAT}";

		$OUT .= "  <gml:featureMember>\n";
		$OUT .= "    <fs:photo fid=\"$FILE\">\n";
		$OUT .= "      <fs:geometry>\n";
		$OUT .= "        <gml:Point>\n";
		$OUT .= "	  <gml:coordinates>$latlong</gml:coordinates>\n";
		$OUT .= "	</gml:Point>\n";
		$OUT .= "      </fs:geometry>\n";
		$OUT .= "      <fs:title>$COMMENT</fs:title>\n";
		$OUT .= "      <fs:file>$FILE</fs:file>\n";
		$OUT .= "      <fs:img_url>$THUMB</fs:img_url>\n";
		$out .= "      <fs:accuracy>16</fs:accuracy>\n";
		$OUT .= "    </fs:photo>\n";
		$OUT .= "  </gml:featureMember>\n";
	}
}
