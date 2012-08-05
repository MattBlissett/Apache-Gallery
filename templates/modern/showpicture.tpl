<div id="page">
	<div id="menu">
		{ $MENU }
	</div>

	<div id="directory">
		<div id="picture">
			Viewing picture { $NUMBER } of { $TOTAL } at { $RESOLUTION } pixels<br/>
			<img src="{ $SRC }"><br/>
			Size [ { $SIZES } ]<br/>
			Slideshow [ { $SLIDESHOW } ]
		</div>

		<div id="nav">
			<span class="nav left" width="20%">{ $BACK }</span>
			<span class="nav right" width="20%">{ $NEXT }</span>
			<p class="info">
				{ $EXIF_DATETIMEORIGINAL }
				| { $EXIF_EXPOSURETIME }s
				| { $EXIF_ISOSPEEDRATINGS }iso
				| { $EXIF_FOCALLENGTH }
				| { $EXIF_MAXAPERTUREVALUE }
			</p>
			<span class="info">{ $PICTUREINFO }</span>

{
	if ($EXIF_GPSSTATUS eq 'A' || $EXIF_GPSSTATUS eq 'V' && $EXIF_GPSLATITUDE ne '' || $EXIF_GPSLATITUDE ne '') {
		$pin = 'red';
		if ($EXIF_GPSSTATUS eq 'A') { $pin = 'yellow'; }
		if ($EXIF_GPSSTATUS eq 'V') { $pin = 'gray'; }

		$latlong = "";
		if ($EXIF_GPSLATITUDEREF eq 'S') { $latlong .= "-"; $lat = "-" };
		$latlong .= "${EXIF_GPSLATITUDE},";
		$lat .= "${EXIF_GPSLATITUDE},";
		if ($EXIF_GPSLONGITUDEREF eq 'W') { $latlong .= "-"; $long = "-" };
		$latlong .= "${EXIF_GPSLONGITUDE}";
		$long .= "${EXIF_GPSLONGITUDE}";

		$OUT .= "<script type='text/javascript'>\n";
		$OUT .= "  var llat = '$lat';\n";
		$OUT .= "  var llong = '$long';\n";
		$OUT .= "  var latlong = '$latlong';\n";
		$OUT .= "  var status = '$EXIF_GPSSTATUS';\n";
		$OUT .= "</script>\n";
		$OUT .= "<noscript>\n";
		$OUT .= "\t<a href='http://maps.google.com/maps/api/staticmap?center=${latlong}&zoom=14&size=800x600&maptype=hybrid&sensor=false&markers=size:small|color:${pin}|${latlong}'>";
		$OUT .=     "<img class='smallmap' src='http://maps.google.com/maps/api/staticmap?center=${latlong}&zoom=14&size=160x160&maptype=hybrid&sensor=false&markers=size:small|color:${pin}|${latlong}' alt='Map showing ${latlong}' title='Location: ${latlong}'/>";
		$OUT .= "</a>\n";
		$OUT .= "</noscript>\n";
		$OUT .= "<div id='map' class='smallmap'></div>\n";
	}
}

			<ul class="detail">
				<li>Flash => {$EXIF_FLASH}</li>
				<li>MeteringMode => {$EXIF_METERINGMODE}</li>
				<li>Camera => {$EXIF_MAKE} {$EXIF_MODEL}</li>
				<li>WhiteBalance => {$EXIF_WHITEBALANCE}</li>
				<li>ExposureMode => {$EXIF_EXPOSUREMODE}</li>
				<li>MaxApertureValue => {$EXIF_MAXAPERTUREVALUE}</li>
				<li>FNumber => {$EXIF_FNUMBER}</li>
			</ul>
		</div>
		<div id="clear"></div>
	</div>
</div>

<script type="text/javascript">
  smallmap(llat, llong, status);
</script>
