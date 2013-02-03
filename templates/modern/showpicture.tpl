<div id="page">
	<div id="menu">{ $MENU }</div>

	<div id="directory">
		<div id="picture">
			Viewing picture { $NUMBER } of { $TOTAL } at { $RESOLUTION } pixels<br/>
			<img rel="foaf:primaryTopicOf" src="{ $SRC }" alt="{ $TITLE }"/><br/>
			Size [ { $SIZES } ]<br/>
			Slideshow [ { $SLIDESHOW } ]
		</div>

		<div id="nav">
			<span class="nav left">{ $BACK }</span>
			<span class="nav right">{ $NEXT }</span>
			<p class="info" about="?orig"> <!-- Not quite right -->
				<span property="dc:created" content="{ $EXIF_DATETIMEORIGINAL }" datatype="xsd:date">{ $EXIF_DATETIMEORIGINAL }</span>
				| { $EXIF_EXPOSURETIME }s
				| { $EXIF_ISOSPEEDRATINGS }iso
				| { $EXIF_FOCALLENGTH }
				| { $EXIF_MAXAPERTUREVALUE }
			</p>
			<div class="info" about="?orig">{ $PICTUREINFO }</div>

{
	if ($EXIF_GPSSTATUS eq 'A' || $EXIF_GPSSTATUS eq 'V' && $EXIF_GPSLATITUDE ne '' || $EXIF_GPSLATITUDE ne '') {
		$pin = 'red';
		if ($EXIF_GPSSTATUS eq 'A') { $pin = 'yellow'; }
		if ($EXIF_GPSSTATUS eq 'V') { $pin = 'gray'; }

		$latlong = "";
		if ($EXIF_GPSLATITUDEREF eq 'S') { $latlong .= "-"; $lat = "-" };
		$latlong .= "${EXIF_GPSLATITUDE}";
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
		$OUT .= "\t<div><a href='//maps.google.com/maps/api/staticmap?center=${latlong}&amp;zoom=14&amp;size=800x600&amp;maptype=hybrid&amp;sensor=false&amp;markers=size:small|color:${pin}|${latlong}'>";
		$OUT .=     "<img class='smallmap' src='//maps.google.com/maps/api/staticmap?center=${latlong}&amp;zoom=14&amp;size=160x160&amp;maptype=hybrid&amp;sensor=false&amp;markers=size:small|color:${pin}|${latlong}' alt='Map showing ${latlong}' title='Location: ${latlong}'/>";
		$OUT .= "</a></div>\n";
		$OUT .= "</noscript>\n";
		$OUT .= "<div id='map' class='smallmap'></div>\n";

		my $latNice = $lat;
		my $longNice = $long;

		$OUT .= "<p about='?orig'>Location:\n";
		$OUT .= "\t<span property='geopos:lat' content='$lat'>$latNice</span>,\n";
		$OUT .= "\t<span property='geopos:long' content='$long'>$longNice</span>.\n";
		$OUT .= "</p>\n";
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
		<div class="clear"></div>
	</div>
</div>

<script type="text/javascript">
  smallmap(llat, llong, status);
</script>

<p id="copyleft" about="?orig">This <span href="http://purl.org/dc/dcmitype/StillImage" rel="dc:type">work</span> by <span property="cc:attributionName">Matthew Blissett</span> is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by-sa/3.0/deed.en_GB">Creative Commons Attribution-ShareAlike 3.0 Unported License</a>.<br />Permissions beyond the scope of this license may be available at <a href="/contact/" rel="cc:morePermissions">http://matt.blissett.me.uk/contact/</a>.</p>
