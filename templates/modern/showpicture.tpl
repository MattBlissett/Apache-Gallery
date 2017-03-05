<div id="page">
	<div id="menu">
		{ $MENU }
		<div id="menuButtons">
			<ul id="download"><li>&#10515;{ $ORIGINAL }</li></ul>
			<ul id="size"><li>◱ <ul>{ $SIZES }</ul></ul>
			<ul id="slideshow"><li>⌚ <ul>{ $SLIDESHOW }</ul></li></ul>
		</div>
	</div>

	<div id="directory">
		<div id="picture">
			<img rel="foaf:primaryTopicOf" src="{ $SRC }" alt="{ $TITLE }"/>
		</div>

		<div id="nav">
			<span class="nav left">{ $BACK }</span>
			<span class="nav right">{ $NEXT }</span>
		</div>
	</div>

	<div id="info" about="{ $IMAGEURI }">
		<div id="picturedatetime" property="dc:created" content="{ $EXIF_DATETIMEORIGINAL }" datatype="xsd:date">{ $EXIF_DATETIMEORIGINAL }</div>

		<div id="pictureinfo">{ $PICTUREINFO }</div>

		{ $MAP }

		<ul id="picturedata">
			<li>Exposure time: {$EXIF_EXPOSURETIME}s</li>
			<li>Speed: {$EXIF_ISOSPEEDRATINGS}iso</li>
			<li>Focal length: {$EXIF_FOCALLENGTH}</li>
			<li>Aperture: {$EXIF_MAXAPERTUREVALUE}</li>
			<li>{$EXIF_FLASH}</li>
			<li>Metering mode: {$EXIF_METERINGMODE}</li>
			<li>Camera: {$EXIF_MAKE} {$EXIF_MODEL}</li>
			<li>White balance: {$EXIF_WHITEBALANCE}</li>
			<li>Exposure mode: {$EXIF_EXPOSUREMODE}</li>
			<li>F-number: {$EXIF_FNUMBER}</li>
		</ul>
	</div>
</div>

{ $LICENSE }

<script type="text/javascript">
	var hasInfo = true;
</script>
