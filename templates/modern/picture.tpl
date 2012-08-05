{
	$class = "l" if ($WIDTH > $HEIGHT);
	$class = "p" if ($WIDTH < $HEIGHT);
	$class = "";

	$margintop = (116 - $HEIGHT) / 2;
	$marginleft = (116 - $WIDTH) / 2;

	"";
}
	<a id="{ $FILE }" href="{ $FILEURL }"><img alt="{ $FILE } - { $DATE }" src="{ $SRC }" width="{ $WIDTH }" height="{ $HEIGHT }" class="{ $class }" style="margin: {$margintop}px 0 0 {$marginleft}px;"></a>
